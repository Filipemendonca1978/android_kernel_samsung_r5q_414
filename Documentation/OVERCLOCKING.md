# Overclocking the Samsung Galaxy S10 Lite (SM8150 / Snapdragon 855)

This document describes how CPU frequency overclocking was implemented on the
Samsung Galaxy S10 Lite (codename r5q) powered by the Qualcomm Snapdragon 855
(SM8150) platform.

## Hardware Overview

The Snapdragon 855 uses three CPU clusters managed by the **OSM** (Operating
State Manager) hardware block:

| Cluster | Name     | Cores | Stock Max Freq | Stock Voltage |
|---------|----------|-------|----------------|---------------|
| 0       | L3 cache | -     | 1.6128 GHz     | 840 mV        |
| 1       | pwrcl    | 0-3   | 1.7856 GHz     | 840 mV        |
| 2       | perfcl   | 4-6   | 2.4192 GHz     | 1008 mV       |
| 3       | perfpcl  | 7     | 2.8416 GHz     | 1000 mV       |

(Gold and prime are Kryo 485 Gold / Gold+ cores based on Cortex-A76.)

The OSM hardware stores per-frequency entries in hardware-fused registers:

- `FREQ_REG` (vbase + 0x110): frequency data (lval in bits 7:0)
- `VOLT_REG` (vbase + 0x114): voltage data (mV in bits 11:0)

Each entry is 32 bytes (0x20) apart. The driver reads these during boot in
`clk_osm_read_lut()`.

## Overclocking Approach

### Why not OPP tables or cpufreq hw?

The OSM driver (`clk-cpu-osm.c`) is the real CPU frequency driver on SM8150.
The hardware reads frequency/voltage pairs from fuses and ignores Device Tree
OPP tables. The `qcom-cpufreq-hw` driver is not used on this platform.

### Why not add entries to the OSM table?

The OSM table is stored in hardware fuses and is **read-only**. We confirmed
this experimentally: writes to `VOLT_REG` return the original value on readback.
There is no writable OVERRIDE register exposed on this platform.

### The working approach: PLL register writes

Each cluster has a TRION PLL controlled by registers at the cluster's vbase:

- **PLL_MODE** (vbase + 0x00): mode register, BIT(22) = UPDATE
- **PLL_L_VAL** (vbase + 0x04): L-value (divider) that sets the frequency

The frequency formula is: `f = 19.2 MHz × lval`

Examples:

| Target Freq | lval | Calculation     |
|-------------|------|-----------------|
| 2.4960 GHz  | 130  | 19.2 × 130      |
| 2.5920 GHz  | 135  | 19.2 × 135      |
| 2.8416 GHz  | 148  | 19.2 × 148 (stock prime) |
| 2.9568 GHz  | 154  | 19.2 × 154      |
| 2.9952 GHz  | 156  | 19.2 × 156      |
| 3.0912 GHz  | 161  | 19.2 × 161      |

#### Critical ordering

The PLL write **must happen after** `osm_set_index()`. The OSM hardware
programs the PLL with its fused lval when a new index is written to
`DCVS_PERF_STATE_DESIRED_REG`. Writing our PLL value before that would be
overwritten by the OSM.

Correct sequence in `osm_cpufreq_target_index()`:

1. `osm_set_index(c, index, c->core_num)` -- OSM sets PLL to stock freq
2. Write our lval to `PLL_L_VAL` (vbase + 0x04)
3. Read `PLL_MODE` (vbase + 0x00)
4. Set BIT(22) (UPDATE) and write back
5. Wait 10 µs
6. Clear BIT(22) and write back

```c
writel_relaxed(oc_lval, c->vbase + 0x04);          // PLL_L_VAL
mode = readl_relaxed(c->vbase + 0x00);              // PLL_MODE
writel_relaxed(mode | BIT(22), c->vbase + 0x00);   // UPDATE=1
udelay(10);
writel_relaxed(mode & ~BIT(22), c->vbase + 0x00);  // UPDATE=0
```

### Three places to modify

The overclock needs changes in three locations in `drivers/clk/qcom/clk-cpu-osm.c`:

1. **`clk_osm_read_lut()`** -- override the last entry's frequency in the
   `osm_table[]` array so OPPs and rate limits are correct.

2. **`osm_cpufreq_cpu_init()`** -- override the last entry in the cpufreq
   frequency table so the governor knows the max frequency.

3. **`osm_cpufreq_target_index()`** -- perform the actual PLL register write
   after `osm_set_index()`.

### Voltage

The **VOLT_REG is read-only** on SM8150. Writes are silently ignored. This
was confirmed by readback testing:

```
perfpcl volt 1000mV write 1056mV readback 1000mV
```

The only voltage available is what Qualcomm fused into the hardware. On the
r5q unit tested, the open-loop voltages are:

- perfcl (gold): 1008 mV at 2.4192 GHz
- perfpcl (prime): 1000 mV at 2.8416 GHz

Because voltage cannot be increased, the maximum stable overclock is limited
by the stock voltage. Going above ~3.0 GHz on the prime cluster at 1000 mV
causes performance regression (silent errors from timing violations).

## Verified Configuration

The following has been tested and is stable on the Galaxy S10 Lite:

| Cluster | Stock     | Overclock | lval |
|---------|-----------|-----------|------|
| Gold    | 2.4192 GHz | 2.496 GHz | 130  |
| Prime   | 2.8416 GHz | 2.9568 GHz | 154  |

### Benchmark results (GeekBench 6)

| Config | Single | Multi | Governor |
|--------|--------|-------|----------|
| Stock  | 985    | 2923  | schedutil |
| Stock  | 990    | 3019  | performance |
| OC 2.5 + 2.96 GHz | 991 | 2983 | schedutil |
| OC 2.5 + 2.96 GHz | 998 | 3052 | performance |
| OC 2.5 + 3.0 GHz  | 998 | 2996 | performance |
| OC 2.5 + 3.09 GHz | 987 | 2996 | performance |

### Thermal

- 45 °C during gaming with 2.5 + 2.96 GHz OC
- 50 °C during gaming with 2.5 + 3.0 GHz OC
- No thermal throttling observed (Snapdragon 855 throttle threshold is ~95 °C)

## Files modified

```
drivers/clk/qcom/clk-cpu-osm.c   -- OSM driver (PLL writes)
arch/arm64/configs/r5q_eur_open_defconfig  -- LOG_BUF_SHIFT=19 (debug)
```

## Limitations

- **No voltage control**: The VOLT_REG is hardware-fused and read-only. RPMh
  voltage voting is theoretically possible but requires extensive platform
  integration work.
- **No new frequency entries**: The OSM table size is fixed by fuses. We can
  only replace the last (boost) entry.
- **PLL UPDATE glitch risk**: Toggling the UPDATE bit on a running PLL may
  cause a brief frequency glitch. The 10 µs delay mitigates this.
- **Per-cluster**: Each cluster's PLL must be programmed independently. The
  gold and prime clusters have separate PLLs.

## Possible future work

- RPMh regulator integration for voltage control (`regulator_set_voltage()` on
  `VDD_CX_LEVEL`)
- L3 cache overclock (same PLL mechanism, cluster 0)
- GPU overclock (separate driver, `kgsl-3d0`)
- Memory bus (DDR) overclock via `devfreq`
