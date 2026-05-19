# perf_v2 — JFR Performance Pipeline

Captures Java Flight Recorder data from a live Jira EC2 instance, generates HTML reports, and gates on regression thresholds.

---

## Quick start

### Full pipeline (SSH → capture → analyse)
```bash
./perf_v2/run_pipeline.sh \
  --host        ec2-xx-xx-xx-xx.compute.amazonaws.com \
  --jira-pass   secret \
  --project-key MYPROJ
```

### Full pipeline with baselines (regression gate)
```bash
./perf_v2/run_pipeline.sh \
  --host                    ec2-xx-xx-xx-xx.compute.amazonaws.com \
  --jira-pass               secret \
  --project-key             MYPROJ \
  --baseline-user-migrate   perf_v2/baselines/user_migrate_baseline.json \
  --baseline-project-export perf_v2/baselines/project_export_baseline.json
```
Exit code: `0` = pass, `1` = regression detected.

### Already have a .jfr file?
```bash
# No baseline — just generate HTML + metrics
./perf_v2/run_analyse.sh --jfr perf_output/user_migrate.jfr

# With baseline — regression gate included
./perf_v2/run_analyse.sh \
  --jfr      perf_output/user_migrate.jfr \
  --baseline perf_v2/baselines/user_migrate_baseline.json
```

---

## Files

| File | Purpose |
|------|---------|
| `run_pipeline.sh` | Entry point: SSH capture + analyse for both phases |
| `run_analyse.sh` | Entry point: analyse an existing `.jfr` file |
| `01_capture.sh` | SSH to EC2, start JFR, synchronous curl, dump, SCP |
| `02_extract.py` | Parse JFR → `_raw.json` (slow, ~30s, run once) |
| `03_metrics.py` | `_raw.json` → `_metrics.json` + `_comparison.json` |
| `04_html.py` | `_raw.json` → `_report.html` (re-run instantly, no JFR needed) |
| `jfr_lib.py` | JFR extraction library (imported by `02_extract.py`) |
| `jfr_compare.py` | Comparison library (imported by `03_metrics.py`) |
| `jfr_html.py` | HTML generation library (imported by `04_html.py`) |
| `baselines/` | Sample baseline JSON files |

---

## Outputs (all in `perf_output/` or `--output-dir`)

```
user_migrate_raw.json          raw parsed JFR events
user_migrate_metrics.json      scalar summary (CI artifact / new baseline candidate)
user_migrate_comparison.json   regression result vs baseline
user_migrate_report.html       visual report — open in browser

project_export_raw.json
project_export_metrics.json
project_export_comparison.json
project_export_report.html
```

### Re-generate HTML without re-parsing the JFR
Stages 3 and 4 read from `_raw.json`, not the JFR file. So if you only change the HTML layout:
```bash
python3 perf_v2/04_html.py \
  --raw perf_output/user_migrate_raw.json \
  --out perf_output \
  --baseline perf_v2/baselines/user_migrate_baseline.json
```

---

## Saving a new baseline
After a known-good run, promote the metrics files to baselines:
```bash
cp perf_output/user_migrate_metrics.json   perf_v2/baselines/user_migrate_baseline.json
cp perf_output/project_export_metrics.json perf_v2/baselines/project_export_baseline.json
git add perf_v2/baselines/ && git commit -m "Update JFR baselines"
```

---

## How thresholds work

Thresholds flow through three layers:

```
run_analyse.sh --thresh-gc-pause 30
      │
      ├─► 03_metrics.py --thresh-gc-pause 30   → writes _comparison.json, exits 0/1
      │
      └─► 04_html.py    --thresh-gc-pause 30   → colours regression table in HTML
```

Both `03_metrics.py` and `04_html.py` receive the **same threshold flags** from `run_analyse.sh`. That is why the HTML report shows the same red/green cells as the CLI output — they use identical thresholds.

## Sample command with baselines and thresholds

```bash
./perf_v2/run_analyse.sh \
  --jfr       may18_proj_1.jfr \
  --out       output \
  --baseline  perf_v2/baselines/project_export_baseline.json \
  --thresh-cpu         30 \
  --thresh-heap        30 \
  --thresh-gc-pause    30 \
  --thresh-gc-full      0 \
  --thresh-db-reads    20 \
  --thresh-db-latency  30 \
  --thresh-api-latency 30 \
  --thresh-blocking    30 \
  --thresh-threads     20 \
  --thresh-exceptions  50
```

These are also the defaults, so this is equivalent to just:

```bash
./perf_v2/run_analyse.sh \
  --jfr      may18_proj_1.jfr \
  --out      output \
  --baseline perf_v2/baselines/project_export_baseline.json
```

Only pass `--thresh-*` when you want to override a specific threshold.

## Threshold flags (all optional, shown with defaults)
```
--thresh-cpu 30          % increase in JVM CPU avg
--thresh-heap 30         % increase in heap peak
--thresh-gc-pause 50     % increase in GC total pause
--thresh-gc-full 0       any new Full GC = regression
--thresh-db-reads 20     % increase in DB query count
--thresh-db-latency 30   % increase in DB avg latency
--thresh-api-latency 30  % increase in API avg latency
--thresh-blocking 30     % increase in thread park total
--thresh-threads 20      % increase in peak thread count
--thresh-exceptions 50   % increase in exception count
```
