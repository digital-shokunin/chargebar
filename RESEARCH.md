# Battery Research — M4 MacBook Air (Mac16,12)

## Battery specifications (from ioreg)

| Property | Value |
|---|---|
| Design capacity | 4629 mAh |
| Nominal pack voltage | 12.49 V |
| Design energy | ~57.8 Wh |
| Cells | 3S (three series, ~4.15 V each) |
| Cell voltage max | ~4.20 V (100% SoC) |
| Chemistry (inferred) | Lithium-ion polymer, cobalt-based cathode (LCO or NMC) — Apple doesn't publish, but 4.2 V max charge rules out LFP |
| Cycle count (David's, 2026-07-14) | 55 |
| Max capacity today | 98% |
| Condition | Normal |

Battery is essentially new (98% at 55 cycles) — good starting point for aggressive longevity management.

## Charge limit vs cycle life — established science

Cycle life for cobalt-based Li-ion cells doubles roughly every 0.10 V reduction in top-of-charge voltage. Empirical data (Battery University, Argonne National Lab, university battery aging studies):

| Top-of-charge | Cell V | Rough cycles to 80% health | Multiplier vs 100% |
|---|---|---|---|
| 100% | 4.20 V | ~500 | 1x (baseline) |
| ~85% | 4.15 V | ~800 | ~1.6x |
| **~80%** | **4.10 V** | **~1200** | **~2.4x** |
| **~75%** | **4.05 V** | **~1800** | **~3.6x** |
| ~70% | 4.00 V | ~2500 | ~5x |
| ~60% | 3.90 V | ~4000+ | ~8x |
| ~50% (storage) | 3.80 V | ~6000+ | ~12x |

Depth of discharge (DoD) is the other big factor — shallow cycles (e.g. 70%→80%) age the cell 3-5x less than deep cycles (0%→100%). Temperature is #2 factor after cycling stress: keep the pack under ~35 °C.

## Recommendation for David

**Sweet spot: 75%** (with option to sail down to 65% before topping up).

Reasoning:
- You're on AC most of the workday (dev at desk, calendar suggests indoor time)
- You've got a healthy new battery — bank the longevity now, don't wait for degradation
- 75% vs 80% costs you ~5 Wh of usable capacity (~15-30 min of light work) but gains ~50% more cycles
- Below 70% starts to hurt on days you actually need runtime (travel, meetings away from adapter)
- Apple's native cap can't do 75% — this is exactly why the DIY replacement exists

### If you're willing to accept less runtime
**70%** — even better longevity (~5x baseline). Only pick this if you're rarely away from AC and always carry the adapter when you are.

### If you want a "set and forget" that Apple already provides
**80%** — Apple's native, hardware-enforced, no third-party code needed. Still 2.4x baseline. Perfectly reasonable.

### Never
- **100%** — 500 cycles and you're at 80% health. Wasteful on a device you'll own for 5+ years.
- **Below 50%** on daily use — you're leaving too much capacity on the table.

## Feature implications for chargebar

The research points at three features Apple doesn't offer that would actually matter:

1. **Sub-80% cap** — 75% is the biggest single win over Apple's native
2. **Sailing mode** — hold at 75%, let it drift to 65% before topping. Fewer charge pulses = less cycling stress + LED stays green longer
3. **Temperature-aware cap** — throttle to 70% when pack is >30 °C (summer, heavy load); allow 80% when cool

## Sources
- Battery University (batteryuniversity.com) — cadex-authored, industry-standard reference
- Argonne National Lab battery aging studies
- Apple's own guidance: "Optimized Battery Charging" white paper (holds at 80% by default because that's the empirical sweet spot for their cells)
- Isidor Buchmann, *Batteries in a Portable World* (4th ed.)

Recent (2023-2025) academic work on shallow-cycling strategies (Stanford SLAC, MIT) supports the same conclusions: charge window management dominates chemistry choice for practical cycle life.
