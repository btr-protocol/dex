//! Deterministic evaluator for BTR oracle-price policies on cached NXR 30-second bars.
//! No fitting occurs here: every run is fully parameterized and emits one JSON record.

use aimm_sim::amm::Amm;
use aimm_sim::amm::aimm::{Aimm, AimmParams, OracleMode};
use std::collections::HashMap;
use std::env;
use std::fs;

const BPS: f64 = 10_000.0;
const PBPS_PER_BP: f64 = 100.0;

#[derive(Clone, Copy)]
struct Bar {
    ts_ms: i64,
    close: f64,
    vbid: f64,
    vask: f64,
    confidence_bps: f64,
}

#[derive(Default)]
struct Metrics {
    lvr: f64,
    toxic_volume: f64,
    organic_volume: f64,
    organic_requested_volume: f64,
    organic_cost: f64,
    push_oev: f64,
    push_oev_max: f64,
    out_of_band: usize,
    coverage_sum: f64,
    coverage_max_dev: f64,
    spot_errors_bps: Vec<f64>,
    center_errors_bps: Vec<f64>,
    user_costs_bps: Vec<f64>,
    push_jumps_bps: Vec<f64>,
}

fn args() -> HashMap<String, String> {
    let raw: Vec<String> = env::args().skip(1).collect();
    let mut out = HashMap::new();
    let mut i = 0;
    while i < raw.len() {
        let key = raw[i].trim_start_matches("--").to_string();
        if i + 1 < raw.len() && !raw[i + 1].starts_with("--") {
            out.insert(key, raw[i + 1].clone());
            i += 2;
        } else {
            out.insert(key, "true".to_string());
            i += 1;
        }
    }
    out
}

fn get<T: std::str::FromStr>(args: &HashMap<String, String>, key: &str, default: T) -> T {
    args.get(key)
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}

fn get_string(args: &HashMap<String, String>, key: &str, default: &str) -> String {
    args.get(key)
        .cloned()
        .unwrap_or_else(|| default.to_string())
}

fn decode_confidence(encoded: f64) -> f64 {
    let x = encoded / 16.0;
    (x * x) / 10_000.0
}

fn load_flows(path: &str) -> HashMap<i64, (f64, f64)> {
    let text = fs::read_to_string(path).unwrap_or_else(|error| panic!("read {path}: {error}"));
    let mut flows = HashMap::new();
    for (line_no, line) in text.lines().enumerate() {
        if line_no == 0 {
            continue;
        }
        let fields: Vec<&str> = line.split(',').collect();
        if fields.len() < 3 {
            continue;
        }
        let ts = fields[0].parse().unwrap_or(0);
        let buy = fields[1].parse::<f64>().unwrap_or(0.0).max(0.0);
        let sell = fields[2].parse::<f64>().unwrap_or(0.0).max(0.0);
        flows.insert(ts, (buy, sell));
    }
    flows
}

fn load_bars(
    path: &str,
    max_return_bps: f64,
    flow_source: &str,
    flows: &HashMap<i64, (f64, f64)>,
) -> (Vec<Bar>, usize) {
    let text = fs::read_to_string(path).unwrap_or_else(|error| panic!("read {path}: {error}"));
    let mut bars = Vec::new();
    let mut rejected = 0usize;
    let mut previous = 0.0;
    for (line_no, line) in text.lines().enumerate() {
        if line_no == 0 {
            continue;
        }
        let fields: Vec<&str> = line.split(',').collect();
        if fields.len() < 9 {
            rejected += 1;
            continue;
        }
        let parse = |index: usize| fields[index].parse::<f64>().unwrap_or(0.0);
        let close = parse(4);
        if close <= 0.0 {
            rejected += 1;
            continue;
        }
        if previous > 0.0 && (close / previous - 1.0).abs() * BPS > max_return_bps {
            rejected += 1;
            continue;
        }
        let ts_ms = fields[0].parse().unwrap_or(0);
        let (vbid, vask) = match flow_source {
            "swaps" => {
                let (buy, sell) = flows
                    .get(&(ts_ms / 30_000 * 30_000))
                    .copied()
                    .unwrap_or((0.0, 0.0));
                (sell, buy)
            }
            "neutral" => (1.0, 1.0),
            _ => (parse(5).max(0.0), parse(6).max(0.0)),
        };
        bars.push(Bar {
            ts_ms,
            close,
            vbid,
            vask,
            confidence_bps: decode_confidence(parse(8)),
        });
        previous = close;
    }
    (bars, rejected)
}

fn segment<'a>(bars: &'a [Bar], name: &str, embargo: usize) -> &'a [Bar] {
    let n = bars.len();
    let train_end = n * 60 / 100;
    let test_end = n * 80 / 100;
    match name {
        "train" => &bars[..train_end.saturating_sub(embargo)],
        "test" => &bars[(train_end + embargo).min(n)..test_end.saturating_sub(embargo)],
        "holdout" => &bars[(test_end + embargo).min(n)..],
        "all" => bars,
        _ => panic!("unknown segment {name}"),
    }
}

fn half_life_decay(timeframe_s: f64, half_life_s: f64) -> f64 {
    if half_life_s <= 0.0 {
        0.0
    } else {
        (-std::f64::consts::LN_2 * timeframe_s / half_life_s).exp()
    }
}

fn policy_mode(args: &HashMap<String, String>, timeframe_s: usize) -> OracleMode {
    let policy = get_string(args, "policy", "hard");
    let theta = get(args, "theta-bp", 10.0) / BPS;
    let heartbeat_s = get(args, "heartbeat-s", 300usize);
    let heartbeat = (heartbeat_s / timeframe_s).max(1);
    match policy.as_str() {
        "hard" => OracleMode::Deviation {
            threshold: theta,
            heartbeat,
        },
        "smooth" => {
            let half_life_s = get(args, "smooth-half-life-s", 60.0);
            let decay = half_life_decay(timeframe_s as f64, half_life_s);
            OracleMode::Smoothing {
                threshold: theta,
                heartbeat,
                alpha: 1.0 - decay,
                breaker: get(args, "breaker-bp", 100.0) / BPS,
            }
        }
        "offset" => OracleMode::TradeOffset {
            threshold: theta,
            heartbeat,
            gain: get(args, "offset-gain", 0.5),
            decay: half_life_decay(timeframe_s as f64, get(args, "offset-half-life-s", 150.0)),
            max_offset: get(args, "offset-cap-bp", 10.0) / BPS,
        },
        "adaptive" => OracleMode::Adaptive {
            theta_floor: get(args, "theta-floor-bp", 1.0) / BPS,
            theta_cap: get(args, "theta-cap-bp", 30.0) / BPS,
            heartbeat,
            age_z: get(args, "age-z", 100.0),
            latency_z: get(args, "latency-z", 2.0),
            latency_steps: (get(args, "latency-s", 12usize) / timeframe_s).max(1),
            gas_cost_base: get(args, "gas-usd", 0.003),
        },
        _ => panic!("unknown policy {policy}"),
    }
}

fn percentile(values: &[f64], q: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    sorted[((sorted.len() - 1) as f64 * q).round() as usize]
}

fn mean(values: &[f64]) -> f64 {
    if values.is_empty() {
        0.0
    } else {
        values.iter().sum::<f64>() / values.len() as f64
    }
}

fn arb_once(amm: &mut Aimm, external: f64) -> (f64, f64) {
    let pool = amm.spot(0, 1);
    if pool <= 0.0 {
        return (0.0, 0.0);
    }
    if pool < external {
        let amount = amm.arb_size(0, 1, external);
        if amount <= 0.0 {
            return (0.0, 0.0);
        }
        let quoted = amm.quote(0, 1, amount);
        let expected_profit = quoted * external - amount;
        if expected_profit <= 0.0 {
            return (0.0, 0.0);
        }
        let out = amm.swap(0, 1, amount);
        ((out * external - amount).max(0.0), amount)
    } else {
        let amount = amm.arb_size(1, 0, 1.0 / external);
        if amount <= 0.0 {
            return (0.0, 0.0);
        }
        let quoted = amm.quote(1, 0, amount);
        let expected_profit = quoted - amount * external;
        if expected_profit <= 0.0 {
            return (0.0, 0.0);
        }
        let out = amm.swap(1, 0, amount);
        ((out - amount * external).max(0.0), amount * external)
    }
}

fn organic_buy(
    amm: &mut Aimm,
    amount_base: f64,
    external: f64,
    max_cost_bps: f64,
    metrics: &mut Metrics,
) {
    if amount_base <= 0.0 {
        return;
    }
    metrics.organic_requested_volume += amount_base;
    let quoted = amm.quote(0, 1, amount_base);
    let quoted_cost_bps = (amount_base - quoted * external) / amount_base * BPS;
    if quoted <= 0.0 || quoted_cost_bps > max_cost_bps {
        return;
    }
    let out = amm.swap(0, 1, amount_base);
    if out <= 0.0 {
        return;
    }
    let cost = amount_base - out * external;
    metrics.organic_cost += cost;
    metrics.organic_volume += amount_base;
    metrics.user_costs_bps.push(cost / amount_base * BPS);
}

fn organic_sell(
    amm: &mut Aimm,
    amount_base: f64,
    external: f64,
    max_cost_bps: f64,
    metrics: &mut Metrics,
) {
    if amount_base <= 0.0 || external <= 0.0 {
        return;
    }
    metrics.organic_requested_volume += amount_base;
    let amount_token = amount_base / external;
    let quoted = amm.quote(1, 0, amount_token);
    let quoted_cost_bps = (amount_base - quoted) / amount_base * BPS;
    if quoted <= 0.0 || quoted_cost_bps > max_cost_bps {
        return;
    }
    let out = amm.swap(1, 0, amount_token);
    if out <= 0.0 {
        return;
    }
    let cost = amount_base - out;
    metrics.organic_cost += cost;
    metrics.organic_volume += amount_base;
    metrics.user_costs_bps.push(cost / amount_base * BPS);
}

fn annualized_volatility(bars: &[Bar], timeframe_s: f64) -> f64 {
    let returns: Vec<f64> = bars
        .windows(2)
        .map(|window| (window[1].close / window[0].close).ln())
        .collect();
    if returns.len() < 2 {
        return 0.0;
    }
    let avg = mean(&returns);
    let variance = returns
        .iter()
        .map(|value| (value - avg).powi(2))
        .sum::<f64>()
        / (returns.len() - 1) as f64;
    variance.sqrt() * (365.0 * 86_400.0 / timeframe_s).sqrt()
}

fn calibrate() {
    let params = AimmParams {
        min_fee: 1.0,
        ..AimmParams::default()
    };
    let mut amm = Aimm::new(params, 100.0, 5_000_000.0).with_mode(OracleMode::Deviation {
        threshold: 0.001,
        heartbeat: 10,
    });
    let initial_center = amm.execution_center();
    let token = amm.swap(0, 1, 10_000.0);
    let roundtrip_pnl = amm.swap(1, 0, token) - 10_000.0;
    amm.tick(1);
    amm.set_external_confidence_bps(5.0);
    amm.on_step(101.0, 1);
    let pushed_center = amm.execution_center();
    let confidence_spread_bps = amm.effective_spread_fraction() * BPS;
    let calibrated = (initial_center - 100.0).abs() < 1e-9
        && (pushed_center - 101.0).abs() < 1e-9
        && roundtrip_pnl <= 1e-9
        && confidence_spread_bps >= 2.5
        && amm.coverage(1).is_finite();
    println!(
        "{{\"calibrated\":{},\"initial_center\":{:.8},\"pushed_center\":{:.8},\
         \"roundtrip_pnl\":{:.8},\"confidence_spread_bps\":{:.8},\"physical_bounds\":{}}}",
        calibrated,
        initial_center,
        pushed_center,
        roundtrip_pnl,
        confidence_spread_bps,
        amm.coverage(1) > 0.0,
    );
    if !calibrated {
        std::process::exit(2);
    }
}

fn main() {
    let args = args();
    if args.contains_key("calibrate") {
        calibrate();
        return;
    }

    let data = get_string(&args, "data", "");
    if data.is_empty() {
        panic!("--data is required");
    }
    let timeframe_s = get(&args, "timeframe-s", 30usize);
    let max_return_bps = get(&args, "max-return-bp", 1_000.0);
    let flow_source = get_string(&args, "flow-source", "nxr-depth");
    let flow_data = get_string(&args, "flow-data", "");
    let flows = if flow_source == "swaps" {
        if flow_data.is_empty() {
            panic!("--flow-data is required when --flow-source swaps");
        }
        load_flows(&flow_data)
    } else {
        HashMap::new()
    };
    let (all_bars, rejected_bars) = load_bars(&data, max_return_bps, &flow_source, &flows);
    let segment_name = get_string(&args, "segment", "train");
    let embargo = (get(&args, "embargo-s", 3_600usize) / timeframe_s).max(1);
    let bars = segment(&all_bars, &segment_name, embargo);
    if bars.len() < 100 {
        panic!("insufficient bars in {segment_name}: {}", bars.len());
    }

    let policy = get_string(&args, "policy", "hard");
    let tvl = get(&args, "tvl-usd", 10_000_000.0);
    let daily_turnover = get(&args, "daily-turnover", 0.5);
    let flow_sign = get(&args, "flow-sign", 1.0f64).signum();
    let flow_model = get_string(&args, "flow-model", "gross");
    let gas_usd = get(&args, "gas-usd", 0.003);
    let organic_max_cost_bps = get(&args, "organic-max-cost-bp", 30.0);
    let inclusion_latency_s = get(&args, "inclusion-latency-s", 12usize);
    let inclusion_lag = inclusion_latency_s.div_ceil(timeframe_s);
    let p0 = bars[0].close;
    let params = AimmParams {
        min_fee: get(&args, "min-fee-bp", 0.01) * PBPS_PER_BP,
        max_fee: get(&args, "max-fee-bp", 100.0) * PBPS_PER_BP,
        min_disp: get(&args, "min-disp-pbps", 1_000.0),
        max_disp: get(&args, "max-disp-pbps", 100_000.0),
        stale_z: 0.0,
        ..AimmParams::default()
    };
    let mode = policy_mode(&args, timeframe_s);
    let mut amm = Aimm::new(params, p0, tvl / 2.0).with_mode(mode);
    let tvl0 = amm.tvl(&[1.0, p0]);
    let initial_base = amm.reserve(0);
    let initial_token = amm.reserve(1);
    let base_per_bar = daily_turnover * tvl0 / (86_400.0 / timeframe_s as f64);
    let mut metrics = Metrics::default();
    let mut previous_pushes = amm.push_count();

    for (index, bar) in bars.iter().enumerate() {
        let observed = &bars[index.saturating_sub(inclusion_lag)];
        let step = ((bar.ts_ms - bars[0].ts_ms).max(0) as usize / 1_000 / timeframe_s).max(index);
        amm.tick(step);
        amm.set_external_confidence_bps(observed.confidence_bps);
        let spot_before = amm.spot(0, 1);
        amm.on_step(observed.close, step);
        let spot_after = amm.spot(0, 1);
        let pushed = amm.push_count() > previous_pushes;
        if pushed {
            metrics
                .push_jumps_bps
                .push((spot_after / spot_before - 1.0).abs() * BPS);
            previous_pushes = amm.push_count();
        }

        let spread = amm.effective_spread_fraction();
        let spot_error = (spot_after / bar.close - 1.0).abs() * BPS;
        let center_error = (amm.execution_center() / bar.close - 1.0).abs() * BPS;
        metrics.spot_errors_bps.push(spot_error);
        metrics.center_errors_bps.push(center_error);
        if spot_error > spread * BPS {
            metrics.out_of_band += 1;
        }

        let mut first_arb = true;
        for _ in 0..8 {
            let (profit, volume) = arb_once(&mut amm, bar.close);
            if profit <= 0.0 {
                break;
            }
            metrics.lvr += profit;
            metrics.toxic_volume += volume;
            if pushed && first_arb {
                metrics.push_oev += profit;
                metrics.push_oev_max = metrics.push_oev_max.max(profit);
            }
            first_arb = false;
        }

        let total_flow = bar.vbid + bar.vask;
        let raw_buy_share = if total_flow > 0.0 {
            bar.vask / total_flow
        } else {
            0.5
        };
        let buy_share = if flow_sign >= 0.0 {
            raw_buy_share
        } else {
            1.0 - raw_buy_share
        };
        if flow_model == "net" {
            let signed = 2.0 * buy_share - 1.0;
            if signed >= 0.0 {
                organic_buy(
                    &mut amm,
                    base_per_bar * signed,
                    bar.close,
                    organic_max_cost_bps,
                    &mut metrics,
                );
            } else {
                organic_sell(
                    &mut amm,
                    base_per_bar * -signed,
                    bar.close,
                    organic_max_cost_bps,
                    &mut metrics,
                );
            }
        } else if index.is_multiple_of(2) {
            organic_buy(
                &mut amm,
                base_per_bar * buy_share,
                bar.close,
                organic_max_cost_bps,
                &mut metrics,
            );
            organic_sell(
                &mut amm,
                base_per_bar * (1.0 - buy_share),
                bar.close,
                organic_max_cost_bps,
                &mut metrics,
            );
        } else {
            organic_sell(
                &mut amm,
                base_per_bar * (1.0 - buy_share),
                bar.close,
                organic_max_cost_bps,
                &mut metrics,
            );
            organic_buy(
                &mut amm,
                base_per_bar * buy_share,
                bar.close,
                organic_max_cost_bps,
                &mut metrics,
            );
        }

        for _ in 0..4 {
            let (profit, volume) = arb_once(&mut amm, bar.close);
            if profit <= 0.0 {
                break;
            }
            metrics.lvr += profit;
            metrics.toxic_volume += volume;
        }

        let coverage_dev = (amm.coverage(1) - 1.0).abs();
        metrics.coverage_sum += coverage_dev;
        metrics.coverage_max_dev = metrics.coverage_max_dev.max(coverage_dev);
    }

    let days = (bars.last().unwrap().ts_ms - bars[0].ts_ms) as f64 / 86_400_000.0;
    let final_price = bars.last().unwrap().close;
    let final_tvl = amm.tvl(&[1.0, final_price]);
    let hodl = initial_base + initial_token * final_price;
    let net_pnl = final_tvl - hodl;
    let gas_cost = amm.push_count() as f64 * gas_usd;
    let annualizer = if days > 0.0 { 365.0 / days } else { 0.0 };
    let safe_tvl = tvl0.max(1e-18);
    let asset = data
        .rsplit('/')
        .next()
        .unwrap_or(&data)
        .split('_')
        .next()
        .unwrap_or("unknown");
    let physical = net_pnl.is_finite()
        && metrics.lvr.is_finite()
        && metrics.coverage_max_dev.is_finite()
        && amm.coverage(1) > 0.0
        && metrics.user_costs_bps.iter().all(|value| value.is_finite());

    println!(
        "{{\"asset\":\"{}\",\"segment\":\"{}\",\"policy\":\"{}\",\"bars\":{},\"days\":{:.8},\
         \"rejected_bars\":{},\"annual_vol\":{:.8},\"flow_source\":\"{}\",\
         \"flow_model\":\"{}\",\"flow_sign\":{:.0},\"inclusion_latency_s\":{},\
         \"net_apr\":{:.8},\"net_after_gas_apr\":{:.8},\"lvr_apr\":{:.8},\
         \"push_oev_apr\":{:.8},\"push_oev_max_usd\":{:.8},\"pushes\":{},\"pushes_per_day\":{:.8},\
         \"gas_usd_per_day\":{:.8},\"organic_volume\":{:.8},\"organic_fill_rate\":{:.8},\
         \"toxic_volume\":{:.8},\
         \"organic_cost_bps\":{:.8},\"user_cost_mean_bps\":{:.8},\"user_cost_p95_bps\":{:.8},\
         \"spot_error_mean_bps\":{:.8},\"spot_error_p95_bps\":{:.8},\
         \"center_error_mean_bps\":{:.8},\"center_error_p95_bps\":{:.8},\
         \"push_jump_mean_bps\":{:.8},\"push_jump_p95_bps\":{:.8},\"push_jump_max_bps\":{:.8},\
         \"time_outside_band\":{:.8},\"coverage_final\":{:.8},\"coverage_mean_dev\":{:.8},\
         \"coverage_max_dev\":{:.8},\"physical_bounds\":{}}}",
        asset,
        segment_name,
        policy,
        bars.len(),
        days,
        rejected_bars,
        annualized_volatility(bars, timeframe_s as f64),
        flow_source,
        flow_model,
        flow_sign,
        inclusion_latency_s,
        net_pnl / safe_tvl * annualizer,
        (net_pnl - gas_cost) / safe_tvl * annualizer,
        metrics.lvr / safe_tvl * annualizer,
        metrics.push_oev / safe_tvl * annualizer,
        metrics.push_oev_max,
        amm.push_count(),
        amm.push_count() as f64 / days.max(1e-18),
        gas_cost / days.max(1e-18),
        metrics.organic_volume,
        metrics.organic_volume / metrics.organic_requested_volume.max(1e-18),
        metrics.toxic_volume,
        metrics.organic_cost / metrics.organic_volume.max(1e-18) * BPS,
        mean(&metrics.user_costs_bps),
        percentile(&metrics.user_costs_bps, 0.95),
        mean(&metrics.spot_errors_bps),
        percentile(&metrics.spot_errors_bps, 0.95),
        mean(&metrics.center_errors_bps),
        percentile(&metrics.center_errors_bps, 0.95),
        mean(&metrics.push_jumps_bps),
        percentile(&metrics.push_jumps_bps, 0.95),
        metrics.push_jumps_bps.iter().copied().fold(0.0, f64::max),
        metrics.out_of_band as f64 / bars.len() as f64,
        amm.coverage(1),
        metrics.coverage_sum / bars.len() as f64,
        metrics.coverage_max_dev,
        physical,
    );
    if !physical {
        std::process::exit(3);
    }
}
