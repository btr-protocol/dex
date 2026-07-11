// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title VenusAddresses — BSC mainnet Venus Core Pool pins (scout 2026-07-11).
/// @dev Chapel: do NOT wire live Venus underlyings to BTR pools — use MockVenus on BTR mocks.
library VenusAddresses {
    address internal constant COMPTROLLER = 0xfD36E2c2a6789Db23113685031d7F16329158384;

    address internal constant VUSDT = 0xfD5840Cd36d94D7229439859C0112a4185BC0255;
    address internal constant VUSDC = 0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8;
    address internal constant VETH = 0xf508fCD89b8bd15579dc79A6827cB4686A3592c8;
    address internal constant VBTC = 0x882C173bC7Ff3b7786CA16dfeD3DFFfb9Ee7847B;
    address internal constant VWBNB = 0x6bCa74586218dB34cdB402295796b79663d816e9;
    address internal constant VFDUSD = 0xC4eF4229FEc74Ccfe17B2bdeF7715fAC740BA0ba;
    address internal constant VDAI = 0x334b3eCB4DCa3593BCCC3c7EBD1A1C1d1780FBF1;

    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address internal constant ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address internal constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant FDUSD = 0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409;
    address internal constant DAI = 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3;
}
