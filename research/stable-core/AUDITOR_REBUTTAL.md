# REBUTTAL

**De :** lead BTR DEX · **À :** l'auditeur · **Objet :** réponse point par point aux critiques *stratégiques*
· **Date :** 2026-07-08

Préambule. On ne discute pas ici les deux bugs de tête : ils sont confirmés au niveau source et corrigés
(route-discovery Router, commit `5daf76c` ; clamp de déviation par feed contre une clé oracle compromise,
`46fab34`), avec tests de régression. Ce mémo traite uniquement les cinq thèses *stratégiques*. Là où tu as
raison, on le dit sans détour ; là où c'est mesurable, on chiffre. Tout est vérifié contre le Solidity réel
(`dex/evm/src`), file:line à l'appui.

---

## (1) « Oracle-PMM, pas un nouvel AMM — re-mix de briques déjà livrées (Lifinity/Dodo/Swaap/Hashflow) »
**PARTIELLEMENT D'ACCORD.**

On concède la lignée, et on la documente déjà : réservation-price d'Avellaneda-Stoikov, toll de flux informé
de Glosten-Milgrom, cadrage Bergault/Guéant. Oui, c'est une synthèse, pas une invention ex nihilo. Mais « re-mix »
efface trois différenciateurs qui ne sont dans *aucune* des briques citées prises isolément :

- **Hub multi-actifs + mur convexe de couverture (coverage-toll).** `_covToll` (`Pricing.sol:653`), piloté par
  `kappaCovBps`, taxe **le seul côté de sortie drainé** (`Pricing.sol:350` ; base = numéraire, `kappaCovBps`
  reste 0, `:422`) et le péage n'est pas crédité au trader ⇒ il reste dans la réserve = skim gracieux vers le
  surplus LP. C'est précisément le mécanisme que *tu* notes le plus haut. Dodo/Swaap n'ont pas ce mur convexe
  par-actif sur un hub partagé.
- **Mode oracle externe|interne par actif.** `ORACLE_MODE_EXTERNAL=0` / `ORACLE_MODE_INTERNAL=1`
  (`Constants.sol:75-76`), branché dans `_fetchFeed` (`Pricing.sol:615`) : en interne, feed de peg synthétique
  jamais périmé (mark constant ⇒ pas d'écriture par-swap ⇒ la fuite LVR au séquenceur monopolistique s'annule) ;
  en externe, mark keeper frais. Le *même pool* mixe les deux selon l'actif. Les PMM cités sont mono-mode.
- **Open-source.** Lifinity/Hashflow (et les prop-AMM Solana : HumidiFi/Obric/SolFi) sont fermés. Méthodo
  ouverte, spread/skew/toll = fonctions on-chain déterministes auditables.

Verdict : la *filiation* est juste, la *conclusion* « rien de neuf » ne l'est pas. La combinaison
hub-unique multi-actifs + mur convexe + mode-par-actif + ouvert n'est aucune brique existante.

## (2) « LVR-immune = FAUX, le risque est relocalisé sur la staleness du keeper »
**D'ACCORD** — et on dit déjà exactement ça (`project_aimm_paper_validation`, `AUDITOR_BRIEFING.md`).

Le quoting sur mark frais (`Oracle.mark` lit `lastPriceB64`, pas l'EMA — `Oracle.sol:13-14`) supprime le LVR
*de retard d'EMA*, pas le LVR tout court. Le LVR résiduel = l'écart de mark borné par θ jusqu'au push suivant,
**partiellement recapturé** par le skew d'inventaire (dérive A-S entre pushes). On ne prétend pas l'immunité ;
on prétend un résiduel *borné et tarifé* : prime de staleness σ·√(excès) au-delà de la grâce keeper (ttl/2)
(`_staleTerm` `Pricing.sol:395`, `_readOracleStale:400`), puis halt dur au TTL. Chemin de correction déjà
cadré : grâce heartbeat + TTL court + prime committée. « Immune » était le mauvais mot ; « LVR d'EMA éliminé,
LVR de staleness borné+tarifé » est le bon.

## (3) « Double spread sur les croisements spoke→spoke »
**PARTIELLEMENT D'ACCORD — et surtout faux pour le core stable, vérifié en code.**

Distinguer deux topologies :

- **Intra-hub (le cas stable-core).** Un swap spoke→spoke dans un *même* pool (base=USDC) est **un seul**
  `getAnchorPathQuote`, chemin `[spokeA, base, spokeB]`. Le spread est calculé **une fois au niveau chemin** :
  `_pathSpread` (`Pricing.sol:376`) prend le **max** des endpoints (σ/vega/confidence/staleness) + `minFeePath`
  — pas une somme par-leg ; `_walkLegs` accumule en **max**, pas en somme (`Pricing.sol:467-470`). La fee est
  prélevée **une fois** : `feeOut = montant·spreadBps/(2·1e6)` (`_settleQuote:358`) = un seul demi-spread sur la
  sortie ; le commentaire du code rejette explicitement un demi-spread côté entrée comme « phantom revenue ».
  Le péage convexe `_covToll` est lui aussi prélevé **une seule fois**, sur l'endpoint de sortie (`:350`). Donc
  un croisement intra-hub paie **1 spread + 1 péage, pas deux.**
- **Où ton « double spread » est réel :** entre **deux pools distincts** (Router two-hop, `Router.sol:127`) =
  deux `getSwapQuote` indépendants = deux demi-spreads = un spread plein. Mais le core stable loge tous les
  stables du cœur dans **un seul hub** ⇒ le croisement est intra-pool, spread unique.

Ce que la jambe base ajoute réellement sur un croisement intra-hub : l'impact-prix de spline **sur 2 arêtes**
au lieu d'1 (`_executeLeg`). Près du peg (couverture ≈ 1) la courbure spline est faible. Donc le surcoût du
croisement = un second leg d'impact-prix, **pas un fee doublé**.

Quantification du mix de flux : base = USDC, l'essentiel du flux est X→USDC = **une seule jambe** (spoke↔base).
Les croisements spoke→spoke (ex. USDT→USDe) sont **minoritaires**, et même eux paient un spread unique intra-hub.
Bilan : la critique tient pour un routing multi-pool générique ; elle ne tient pas pour la topologie stable-core.

## (4) « Coût keeper > fees à petit TVL / pas de PMF / DOA en DEX public / captif seulement »
**EN DÉSACCORD sur le core stable (chiffres), avec une concession sur le DEX générique.**

L'empirie BSC (`web-census.md`, deep-research vérifié 3-0) casse le « captif seulement » :

- **L'incumbent = UN pool.** PCS v3 USDT/USDC 1bp (`0x92b7807b…3121`), ~$35M TVL, ~$5.1M/j, réserves
  **déséquilibrées ~10:1** (31.9M USDT : 3.1M USDC) — range v3 passif épinglé, prix dégradé du côté maigre. Un
  carnet oracle-centré à deux côtés quote *mieux* sur le côté maigre. C'est la surface d'attaque, mesurée.
- **Économie de push.** Coût push BSC ~$0.05-0.10 ; gaté par θ ⇒ ≈ **$5-30/mois**. Fees à $2.5M TVL : ~50% de
  capture d'un flux de $5-7M/j à ~1bp ⇒ ~$250-350/j ⇒ **3.7-5.1% APR brut** vs 0.35% pour le LP incumbent. Le
  coût keeper est **2-3 ordres de grandeur** sous les fees dès $2.5M TVL — le TVL de croisement où le push gaté-θ
  dépasse les fees est *bien en-dessous* de $2.5M. « Coût keeper > fees à petit TVL » est donc mesurablement faux
  à l'échelle stable-core. L'edge = tourner ~10× moins de TVL pour une exécution comparable (oracle-centré ⇒ pas
  besoin du float passif de $35M).
- **Concession :** en **DEX public générique** courant après le TVL de paires volatiles, la thèse est
  réellement faible (flywheel TVL, dépendance agrégateur, pas de moat). On ne défend pas ça. La thèse publique
  qu'on porte est étroite et chiffrée : le *cœur stable* sur BSC, pas un DEX tout-venant.

## (5) « Trust-min 2.5/10, custodial, RFQ déguisé »
**PARTIELLEMENT D'ACCORD.**

On concède la réalité de confiance keeper : **une seule clé oracle aujourd'hui** (`onlyOracle`,
`ExternalOracle.sol:57`). Une clé compromise pouvait marker-to-arbitrary (c'est le D1 qu'on avait *déjà* flaggé).
Durcissement : (a) rôle oracle **2-of-N** ; (b) **clamp de déviation par feed** qu'on vient d'ajouter
(`maxDeviations`, `ExternalOracle.sol:30,204-208`) — borne une clé compromise à maxDev/push, soit une marche
graduelle *monitorable*, pas un one-tx drain ; (c) **planchers/plafonds de réservation** par actif pour les
stables (`reservationPrice`/`reservationPriceMax`, `PoolIO.sol:111-119`, `Admin.sol:192`) = borne absolue
keeper-indépendante. Un 2.5/10 *sur la confiance-clé actuelle* est équitable.

Mais « RFQ déguisé » sous-estime le substrat. Contrairement à un RFQ (quotes signées off-chain, redeem
on-chain, maker qui coupe le flux à volonté) : **règlement 100% on-chain** contre des réserves mutualisées,
atomique ; **substrat d'inventaire non-drainable** (planchers de réservation + mur de couverture + halts de
depeg base `_readBasePriceOrHalt` + clamp de déviation bornent le pire cas — un maker RFQ n'a qu'à arrêter de
quoter, ici les gardes on-chain persistent) ; **LPs passifs rémunérés** (split proto/lp, `_settleQuote`) — un
RFQ n'a pas de côté LP passif ; **méthodo ouverte** (pricing = fonctions déterministes auditables, pas un moteur
maker privé). C'est un oracle-PMM on-chain à LPs passifs et substrat non-custodial *au sens RFQ* ; le goulot de
confiance actuel (clé unique) est réel et en cours de durcissement — ce n'est pas un RFQ caché.

---

## Synthèse
| # | Thèse | Verdict |
|---|---|---|
| 1 | Oracle-PMM / re-mix de briques | **PARTIELLEMENT** — lignée concédée, 3 différenciateurs (mur convexe, mode-par-actif, open) tiennent |
| 2 | LVR-immune = faux, risque → staleness | **D'ACCORD** — déjà notre position ; LVR d'EMA éliminé, staleness borné+tarifé |
| 3 | Double spread spoke→spoke | **PARTIELLEMENT** — vrai en cross-pool, faux intra-hub (spread unique) ; flux dominant X→USDC mono-jambe |
| 4 | Pas de PMF / DOA / captif | **EN DÉSACCORD** sur le core stable (push ≈$5-30/mo ≪ fees @ $2.5M) ; concédé pour le DEX générique |
| 5 | Trust-min 2.5/10 / RFQ déguisé | **PARTIELLEMENT** — clé unique concédée + durcie ; substrat on-chain non-drainable ≠ RFQ |

Nos deux différenciateurs les plus solides restent : (i) le mur convexe de couverture sur hub multi-actifs, et
(ii) l'edge oracle-centré structurel qui permet ~10× moins de TVL — tous deux chiffrés, pas rhétoriques. Notre
vrai risque n° 1, tu l'as bien vu, c'est la confiance keeper ; c'est aussi notre edge (push rapide/léger), et on
le borne sans ralentir le happy-path. Merci pour la rigueur du rapport — il a rendu le code meilleur.
