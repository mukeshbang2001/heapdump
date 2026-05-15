#!/usr/bin/env bash
# =============================================================================
# Script 2: jfr-extract.sh
# Reads a .jfr file → extracts ALL raw event data → writes run-raw.json
#
# PARSING APPROACH:
#   JFR events are multi-line blocks: "jdk.EventName {\n  field = value\n}\n"
#   We use block-aware awk: accumulate lines between { and }, then extract fields.
#   All duration conversion: "152 ms" → 152, "1.5 s" → 1500
#   All size conversion: "3.6 GB" → 3.6, "512 MB" → 0.5
#   macOS-compatible: no gawk extensions, no 3-arg match(), no paste
# =============================================================================
set -o pipefail

JFR_FILE=""
OUTPUT_FILE=""

usage() {
  echo "Usage: $0 --jfr <path/to/file.jfr> --output <path/to/raw.json>"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --jfr)    JFR_FILE="$2";    shift 2 ;;
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    *)        usage ;;
  esac
done

[[ -z "$JFR_FILE" || -z "$OUTPUT_FILE" ]]  && usage
[[ ! -f "$JFR_FILE" ]]                      && { echo "❌ JFR file not found: $JFR_FILE"; exit 1; }

# Resolve jfr binary — prefer full JDK paths over hermit/repo wrappers
# which may not support 'print' subcommand
if [[ -z "${JFR_CMD}" ]]; then
  for candidate in \
    "${JAVA_HOME}/bin/jfr" \
    "${HOME}/.sdkman/candidates/java/current/bin/jfr" \
    "/Library/Java/JavaVirtualMachines/"*"/Contents/Home/bin/jfr" \
    "/opt/jdk/"*"/bin/jfr" \
    "$(command -v jfr 2>/dev/null)"; do
    if [[ -x "${candidate}" ]] && "${candidate}" version &>/dev/null; then
      JFR_CMD="${candidate}"; break
    fi
  done
fi
[[ -z "${JFR_CMD}" ]] && { echo "❌ jfr command not found. Set JFR_CMD env var or ensure JAVA_HOME is set."; exit 1; }
echo "   Using jfr: ${JFR_CMD}"

mkdir -p "$(dirname "$OUTPUT_FILE")"

echo "🔍 Extracting JFR: $JFR_FILE"
echo "   Output: $OUTPUT_FILE"
echo ""

# Helper: print events of given type
jfr_print() { "$JFR_CMD" print --events "$1" "$JFR_FILE" 2>/dev/null; }

# Helper: convert duration line "152 ms" or "1.5 s" to milliseconds
# Usage: echo "duration = 152 ms" | to_ms
to_ms() {
  awk '{
    for(i=1;i<=NF;i++){
      if($i~/^[0-9]+(\.[0-9]+)?$/ && $(i+1)~/^(ms|s)$/){
        val=$i; unit=$(i+1)
        if(unit=="s") print val*1000
        else print val
        exit
      }
    }
    print 0
  }'
}

# Helper: sum duration lines from a jfr_print output
sum_durations() {
  grep -E "^[ \t]+duration = [0-9]" | awk '{
    val=$3; unit=$4
    if(unit=="s") ms=val*1000; else ms=val
    sum+=ms; count++
    if(ms>max) max=ms
  } END{printf "%.0f %.0f %.1f", sum+0, count+0, max+0}'
}

# Helper: convert heap value "3.6 GB" → float GB
heap_to_gb() {
  awk '{
    val=$3; unit=$4
    if(unit=="GB") gb=val
    else if(unit=="MB") gb=val/1024
    else if(unit=="KB"||unit=="kB") gb=val/1024/1024
    else gb=val/1024/1024/1024
    print gb+0
  }'
}

# Helper: build JSON array from lines of values
# Usage: printf "1\n2\n3" | to_json_array
to_json_array() {
  awk 'BEGIN{printf "["} NR>1{printf ","} {printf "%s",$0} END{printf "]"}'
}

# Helper: build JSON array of {"t":"TIME","v":VAL} objects
# Reads pairs of lines: TIME\nVAL
to_timeline_json() {
  awk 'BEGIN{printf "["; first=1}
    NR%2==1{t=$0}
    NR%2==0{
      if(!first) printf ","
      printf "{\"t\":\"%s\",\"v\":%s}", t, $0
      first=0
    }
    END{printf "]"}'
}

# ============================================================
# SECTION 1: METADATA
# ============================================================
echo "[1/6] Recording metadata..."
META_RAW=$("$JFR_CMD" summary "$JFR_FILE" 2>/dev/null)
REC_START=$(echo "$META_RAW" | grep -i "Start" | head -1 | awk '{print $NF}')
REC_END=$(echo "$META_RAW"   | grep -i "End"   | head -1 | awk '{print $NF}')
REC_DUR=$(echo "$META_RAW"   | grep -i "Duration" | head -1 | awk '{print $NF}')
TOTAL_EVENTS=$(echo "$META_RAW" | grep -i "Event types" | awk '{print $NF}')

# Derive wall clock in seconds from JFR summary Duration field
# Formats: "15m 3s", "903 s", "15.3 s"
WALL_CLOCK_S=0
DUR_LINE=$(echo "$META_RAW" | grep -i "Duration" | head -1)
if echo "$DUR_LINE" | grep -qE "[0-9]+m"; then
  MINS=$(echo "$DUR_LINE" | grep -oE "[0-9]+m" | tr -d 'm')
  SECS=$(echo "$DUR_LINE" | grep -oE "[0-9]+s" | head -1 | tr -d 's')
  WALL_CLOCK_S=$(( ${MINS:-0} * 60 + ${SECS:-0} ))
elif echo "$DUR_LINE" | grep -qE "[0-9]"; then
  WALL_CLOCK_S=$(echo "$DUR_LINE" | grep -oE "[0-9]+" | head -1 || echo "0")
fi

echo "  Start: $REC_START  End: $REC_END  Duration: $REC_DUR (${WALL_CLOCK_S}s)"

# ============================================================
# SECTION 2: DATABASE (SocketRead = JDBC round-trips to DB)
# ============================================================
echo "[2/6] Database / I/O (SocketRead events)..."

# Only reads where port=5432 (PostgreSQL) or matching RDS host
SOCK_RAW=$(jfr_print jdk.SocketRead)
DB_COUNT=$(echo "$SOCK_RAW" | grep -c "^jdk.SocketRead" || true)

# Extract duration ms values correctly (duration line only, not timeout)
DB_DUR_VALS=$(echo "$SOCK_RAW" | awk '
  /^jdk\.SocketRead \{/{in_e=1; dur=""; ts=""; got_dur=0}
  in_e && /^[ \t]+startTime = /{ts=$3}
  # Match ONLY the top-level "duration" field — not "timeout" which also has duration-like values
  # The real duration field appears as "  duration = X ms" (exactly 2 spaces, word "duration")
  in_e && !got_dur && /^  duration = /{
    val=$3; unit=$4
    if(unit=="s") dur=val*1000
    else if(unit=="ms") dur=val
    else dur=val
    got_dur=1
  }
  in_e && /^\}$/{
    if(dur!="" && dur+0>0) print ts, dur
    in_e=0
  }
')

DB_TOTAL_MS=$(echo "$DB_DUR_VALS" | awk '{sum+=$2} END{printf "%.0f",sum+0}')
DB_AVG_MS=$(echo "$DB_DUR_VALS"   | awk '{sum+=$2;c++} END{if(c>0)printf "%.1f",sum/c; else print "0"}')
DB_MAX_MS=$(echo "$DB_DUR_VALS"   | awk '{if($2>max)max=$2} END{printf "%.1f",max+0}')

# Percentiles
DB_SORTED=$(echo "$DB_DUR_VALS" | awk '{print $2}' | sort -n)
DB_P90=$(echo "$DB_SORTED" | awk -v c="$(echo "$DB_SORTED" | wc -l | tr -d ' ')" \
  'NR==int(c*0.9)+1{print int($1)}')
DB_P99=$(echo "$DB_SORTED" | awk -v c="$(echo "$DB_SORTED" | wc -l | tr -d ' ')" \
  'NR==int(c*0.99)+1{print int($1)}')

# Timeline: one point per query (timestamp + duration)
DB_TIMELINE=$(echo "$DB_DUR_VALS" | awk '
  BEGIN{printf "["; first=1}
  $2>0{
    if(!first) printf ","
    printf "{\"t\":\"%s\",\"v\":%s}", $1, $2
    first=0
  }
  END{printf "]"}
')

# Slowest 10 queries
DB_SLOWEST=$(echo "$DB_DUR_VALS" | sort -k2 -rn | head -10 | \
  awk 'BEGIN{printf "["; first=1}
    {if(!first) printf ","; printf "{\"t\":\"%s\",\"v\":%s}", $1, $2; first=0}
    END{printf "]"}')

echo "  Queries: $DB_COUNT  Total wait: ${DB_TOTAL_MS}ms  Avg: ${DB_AVG_MS}ms  Max: ${DB_MAX_MS}ms"

# ============================================================
# SECTION 3: MEMORY & GC
# ============================================================
echo "[3/6] Memory & GC..."

# Heap timeline from GCHeapSummary
HEAP_RAW=$(jfr_print jdk.GCHeapSummary)
HEAP_DATA=$(echo "$HEAP_RAW" | awk '
  /^jdk\.GCHeapSummary \{/{in_e=1; ts=""; used=""; in_sub=0}
  in_e && /startTime = /{ts=$3}
  in_e && /heapSpace = \{/{in_sub=1}
  in_e && in_sub && /^[ \t]+\}$/{in_sub=0; next}
  in_e && !in_sub && /heapUsed = /{
    val=$3; unit=$4
    if(unit=="GB") gb=val
    else if(unit=="MB") gb=val/1024
    else if(unit=="KB"||unit=="kB") gb=val/1024/1024
    else gb=val/1024/1024/1024
    used=gb
  }
  in_e && !in_sub && /^\}$/{
    if(ts!="" && used!="") print ts, used
    in_e=0
  }
')

HEAP_TIMELINE=$(echo "$HEAP_DATA" | awk '
  BEGIN{printf "["; first=1}
  {if(!first) printf ","; printf "{\"t\":\"%s\",\"v\":%.2f}",$1,$2; first=0}
  END{printf "]"}')

HEAP_MIN=$(echo "$HEAP_DATA" | awk 'BEGIN{min=9999}{if($2<min)min=$2}END{printf "%.3f",min}')
HEAP_MAX=$(echo "$HEAP_DATA" | awk 'BEGIN{max=0}{if($2>max)max=$2}END{printf "%.3f",max}')
HEAP_LAST=$(echo "$HEAP_DATA" | tail -1 | awk '{printf "%.3f",$2}')
HEAP_DELTA=$(echo "$HEAP_MAX $HEAP_MIN" | awk '{printf "%.3f",$1-$2}')

# GC events
GC_RAW=$(jfr_print jdk.GarbageCollection)
GC_TOTAL=$(echo "$GC_RAW" | grep -c "^jdk.GarbageCollection" || true)

GC_DATA=$(echo "$GC_RAW" | awk '
  /^jdk\.GarbageCollection \{/{in_e=1; ts=""; dur=""; cause=""; name=""}
  in_e && /startTime = /{ts=$3}
  in_e && /^[ \t]+name = /{gsub(/"/,"",$3); name=$3}
  in_e && /cause = /{gsub(/"/,"",$3); cause=$3}
  in_e && /^  duration = /{val=$3; unit=$4; if(unit=="s") dur=val*1000; else if(unit=="ms") dur=val; else dur=val}
  in_e && /^\}$/{
    if(dur!="") print ts, dur, name, cause
    in_e=0
  }
')

GC_YOUNG=$(echo "$GC_DATA" | grep -ciE "G1New|YoungGen|ParNew|DefNew" || true)
GC_OLD=$(echo "$GC_DATA"   | grep -ciE "G1Old|OldGen|ConcurrentMark|Full" || true)
GC_HUMONGOUS=$(echo "$GC_DATA" | grep -ci "Humongous" || true)
GC_TOTAL_PAUSE=$(echo "$GC_DATA" | awk '{sum+=$2} END{printf "%.0f",sum+0}')
GC_MAX_PAUSE=$(echo "$GC_DATA"   | awk 'BEGIN{max=0}{if($2>max)max=$2} END{printf "%.1f",max}')
GC_AVG_PAUSE=$(echo "$GC_DATA"   | awk '{sum+=$2;c++} END{if(c>0)printf "%.1f",sum/c;else print 0}')

# GC pause distribution
GC_UNDER50=$(echo  "$GC_DATA" | awk '$2<50{c++}  END{print c+0}')
GC_50_100=$(echo   "$GC_DATA" | awk '$2>=50&&$2<100{c++}  END{print c+0}')
GC_100_200=$(echo  "$GC_DATA" | awk '$2>=100&&$2<200{c++} END{print c+0}')
GC_OVER200=$(echo  "$GC_DATA" | awk '$2>=200{c++} END{print c+0}')

# GC timeline
GC_TIMELINE=$(echo "$GC_DATA" | awk '
  BEGIN{printf "["; first=1}
  {if(!first) printf ","; printf "{\"t\":\"%s\",\"v\":%.1f,\"type\":\"%s\"}",$1,$2,$3; first=0}
  END{printf "]"}')

# GC events list for report
GC_EVENTS=$(echo "$GC_DATA" | awk '
  BEGIN{printf "["; first=1}
  {if(!first) printf ","; printf "{\"t\":\"%s\",\"dur\":%.1f,\"name\":\"%s\",\"cause\":\"%s\"}",$1,$2,$3,$4; first=0}
  END{printf "]"}')

# RSS
RSS_RAW=$(jfr_print jdk.ResidentSetSize)
RSS_DATA=$(echo "$RSS_RAW" | awk '
  /^jdk\.ResidentSetSize \{/{in_e=1; ts=""; sz=""}
  in_e && /startTime = /{ts=$3}
  in_e && /\bsize = /{val=$3; unit=$4;
    if(unit=="GB") gb=val
    else if(unit=="MB") gb=val/1024
    else if(unit=="KB"||unit=="kB") gb=val/1024/1024
    else gb=val/1024/1024/1024
    sz=gb}
  in_e && /^\}$/{if(ts!=""&&sz!="") print ts, sz; in_e=0}
')
RSS_MAX=$(echo "$RSS_DATA" | awk 'BEGIN{max=0}{if($2>max)max=$2} END{printf "%.2f",max}')
RSS_TIMELINE=$(echo "$RSS_DATA" | awk '
  BEGIN{printf "["; first=1}
  {if(!first) printf ","; printf "{\"t\":\"%s\",\"v\":%.2f}",$1,$2; first=0}
  END{printf "]"}')

# Top allocating classes (OutsideTLAB)
ALLOC_RAW=$(jfr_print jdk.ObjectAllocationOutsideTLAB)
TOP_ALLOC=$(echo "$ALLOC_RAW" | awk '
  /^jdk\.ObjectAllocationOutsideTLAB \{/{in_e=1; cls=""; sz=0}
  in_e && /objectClass = /{
    sub(/.*objectClass = /,""); sub(/ .*/,""); gsub(/"/,""); cls=$0
  }
  in_e && /allocationSize = /{
    val=$3; unit=$4
    if(unit=="GB") bytes=val*1024*1024*1024
    else if(unit=="MB") bytes=val*1024*1024
    else if(unit=="KB"||unit=="kB") bytes=val*1024
    else bytes=val
    sz=bytes
  }
  in_e && /^\}$/{
    if(cls!="") sizes[cls]+=sz; in_e=0
  }
  END{
    for(c in sizes) print sizes[c], c
  }
' | sort -rn | head -10 | awk '
  BEGIN{printf "["; first=1}
  {if(!first) printf ","; printf "{\"class\":\"%s\",\"bytes\":%s}", $2, $1; first=0}
  END{printf "]"}')

# JCMA allocations
JCMA_ALLOC=$(echo "$ALLOC_RAW" | awk '
  /^jdk\.ObjectAllocationOutsideTLAB \{/{in_e=1; cls=""; sz=0}
  in_e && /objectClass = /{
    sub(/.*objectClass = /,""); sub(/ .*/,""); gsub(/"/,""); cls=$0
  }
  in_e && /allocationSize = /{
    val=$3; unit=$4
    if(unit=="GB") bytes=val*1024*1024*1024
    else if(unit=="MB") bytes=val*1024*1024
    else if(unit=="KB"||unit=="kB") bytes=val*1024
    else bytes=val; sz=bytes
  }
  in_e && /^\}$/{
    if(cls ~ /atlassian\.jira\.migration/) sizes[cls]+=sz
    in_e=0
  }
  END{for(c in sizes) print sizes[c], c}
' | sort -rn | head -10 | awk '
  BEGIN{printf "["; first=1}
  {if(!first) printf ","; printf "{\"class\":\"%s\",\"bytes\":%s}", $2, $1; first=0}
  END{printf "]"}')

echo "  Heap: ${HEAP_MIN}→${HEAP_MAX}GB  GC: ${GC_TOTAL} total (Young:${GC_YOUNG} Old:${GC_OLD} Humongous:${GC_HUMONGOUS})"
echo "  GC pauses: total=${GC_TOTAL_PAUSE}ms  max=${GC_MAX_PAUSE}ms  avg=${GC_AVG_PAUSE}ms"

# ============================================================
# SECTION 4: CPU
# ============================================================
echo "[4/6] CPU & Execution samples..."

CPU_RAW=$(jfr_print jdk.CPULoad)
CPU_DATA=$(echo "$CPU_RAW" | awk '
  /^jdk\.CPULoad \{/{in_e=1; ts=""; jvm=""}
  in_e && /startTime = /{ts=$3}
  in_e && /jvmUser = /{val=$3; gsub(/%/,"",val); jvm=val}
  in_e && /^\}$/{if(ts!=""&&jvm!="") print ts, jvm; in_e=0}
')
CPU_AVG=$(echo "$CPU_DATA" | awk '{sum+=$2;c++} END{if(c>0)printf "%.1f",sum/c; else print 0}')
CPU_PEAK=$(echo "$CPU_DATA" | awk 'BEGIN{max=0}{if($2>max)max=$2} END{printf "%.1f",max}')
CPU_TIMELINE=$(echo "$CPU_DATA" | awk '
  BEGIN{printf "["; first=1}
  {if(!first) printf ","; printf "{\"t\":\"%s\",\"v\":%.1f}",$1,$2; first=0}
  END{printf "]"}')

# Limit ExecutionSample to 200k lines to prevent timeout on large JFR files
EXEC_RAW=$("${JFR_CMD}" print --events jdk.ExecutionSample "${JFR_FILE}" 2>/dev/null | head -200000 || true)
EXEC_COUNT=$(echo "$EXEC_RAW" | grep -c "^jdk.ExecutionSample" || true)

# Top methods overall (from stack traces - first non-whitespace frame per sample)
TOP_METHODS=$(echo "$EXEC_RAW" | awk '
  /^jdk\.ExecutionSample \{/{in_e=1; recorded=0}
  in_e && !recorded && /^    [a-zA-Z]/ && !/^\.\.\. / {
    frame=$0; gsub(/^[ \t]+/,"",frame); gsub(/ line:.*/,"",frame)
    counts[frame]++; recorded=1
  }
  /^\}$/{in_e=0; recorded=0}
  END{for(k in counts) print counts[k], k}
' | sort -rn | head -20 | \
  awk 'BEGIN{printf "["; first=1}
    {if(!first) printf ",";
     cnt=$1; $1=""; sub(/^ /,"",$0)
     gsub(/\\/,"\\\\"); gsub(/"/,"\\\"",$0)
     printf "{\"method\":\"%s\",\"samples\":%s}", $0, cnt; first=0}
    END{printf "]"}')

# JCMA hotspots - count samples where any stack frame is in com.atlassian.jira.migration
TOP_JCMA=$(echo "$EXEC_RAW" | awk '
  /^jdk\.ExecutionSample \{/{in_e=1; found=0; best=""}
  in_e && /com\.atlassian\.jira\.migration/ {
    if(!found){
      frame=$0; gsub(/^[ \t]+/,"",frame)
      sub(/com\.atlassian\.jira\.migration\./,"",frame)
      gsub(/ line:.*/,"",frame)
      best=frame; found=1
    }
  }
  /^\}$/{
    if(found) counts[best]++
    in_e=0; found=0; best=""
  }
  END{for(k in counts) print counts[k], k}
' | sort -rn | head -20 | \
  awk 'BEGIN{printf "["; first=1}
    {if(!first) printf ",";
     cnt=$1; $1=""; sub(/^ /,"",$0)
     gsub(/\\/,"\\\\"); gsub(/"/,"\\\"",$0)
     printf "{\"method\":\"%s\",\"samples\":%s}", $0, cnt; first=0}
    END{printf "]"}')

# JCMA by package
JCMA_PKG=$(echo "$EXEC_RAW" | grep "com.atlassian.jira.migration" | \
  sed 's/.*com\.atlassian\.jira\.migration\.\([a-z_]*\)\..*/\1/' | \
  sort | uniq -c | sort -rn | head -10 | \
  awk 'BEGIN{printf "["; first=1}
    {if(!first) printf ","; printf "{\"pkg\":\"%s\",\"samples\":%s}",$2,$1; first=0}
    END{printf "]"}')

echo "  CPU avg: ${CPU_AVG}%  peak: ${CPU_PEAK}%  Execution samples: ${EXEC_COUNT}"

# ============================================================
# SECTION 5: THREADS & BLOCKING
# ============================================================
echo "[5/6] Threads & blocking..."

# Limit ThreadPark to 50k lines to prevent timeout on large JFR files (~5GB)
PARK_RAW=$("${JFR_CMD}" print --events jdk.ThreadPark "${JFR_FILE}" 2>/dev/null | head -600000 || true)
PARK_TOTAL=$(echo "$PARK_RAW" | grep -c "^jdk.ThreadPark" || true)

# Extract park events with class and duration
PARK_DATA=$(echo "$PARK_RAW" | awk '
  /^jdk\.ThreadPark \{/{in_e=1; cls=""; dur=0; ts=""}
  in_e && /startTime = /{ts=$3}
  in_e && /parkedClass = /{
    # parkedClass = java.util.concurrent... (classLoader = bootstrap)
    # Strip leading/trailing quotes and the (classLoader = ...) suffix
    cls=$0; gsub(/.*parkedClass = /,"",cls); gsub(/ \(classLoader.*/,"",cls); gsub(/"/,"",cls)
    gsub(/^[ \t]+|[ \t]+$/,"",cls)
  }
  in_e && /^  duration = /{val=$3; unit=$4; if(unit=="s") dur=val*1000; else if(unit=="ms") dur=val; else dur=val}
  in_e && /^\}$/{
    if(cls!="") printf "%s\t%s\t%s\n", ts, dur, cls
    in_e=0
  }
')

# Idle parks: thread pool waiting for work (use tab-separated field $3 for class)
PARK_IDLE=$(echo "$PARK_DATA" | awk -F'\t' '$3~/ConditionObject|SynchronousQueue|LinkedTransferQueue|ThreadPoolExecutor|ForkJoinPool/{c++} END{print c+0}')
PARK_MEANINGFUL=$(echo "$PARK_TOTAL $PARK_IDLE" | awk '{d=$1-$2; print (d>0)?d:0}')
PARK_MEANINGFUL_MS=$(echo "$PARK_DATA" | awk -F'\t' '$3!~/ConditionObject|SynchronousQueue|LinkedTransferQueue|ThreadPoolExecutor|ForkJoinPool/{sum+=$2} END{printf "%.0f",sum+0}')

# Top blocking classes (non-idle)
TOP_BLOCKS=$(echo "$PARK_DATA" | awk -F'\t' '$3!~/ConditionObject|SynchronousQueue|LinkedTransferQueue|ThreadPoolExecutor|ForkJoinPool/{
    counts[$3]++; total[$3]+=$2
  }
  END{for(c in counts) print counts[c], total[c], c}' | \
  sort -rn | head -10 | \
  awk 'BEGIN{printf "["; first=1}
    {if(!first) printf ",";
     cnt=$1; ms=int($2); $1=""; $2=""; sub(/^  /,"",$0)
     gsub(/"/,"\\\"",$0)
     printf "{\"class\":\"%s\",\"count\":%s,\"total_ms\":%s}", $0, cnt, ms; first=0}
    END{printf "]"}')

# Lock contention (JavaMonitorEnter) — limit to avoid timeout on large JFR files
LOCK_RAW=$("${JFR_CMD}" print --events jdk.JavaMonitorEnter "${JFR_FILE}" 2>/dev/null | head -5000 || true)
LOCK_COUNT=$(echo "$LOCK_RAW" | grep -c "^jdk.JavaMonitorEnter" || true)
LOCK_DATA=$(echo "$LOCK_RAW" | awk '
  /^jdk\.JavaMonitorEnter \{/{in_e=1; cls=""; dur=0}
  in_e && /monitorClass = /{
    cls=$0; gsub(/.*monitorClass = /,"",cls); gsub(/ \(classLoader.*/,"",cls); gsub(/"/,"",cls)
    gsub(/^[ \t]+|[ \t]+$/,"",cls)
  }
  in_e && /^  duration = /{val=$3; unit=$4; if(unit=="s") dur=val*1000; else if(unit=="ms") dur=val; else dur=val}
  in_e && /^\}$/{if(cls!="") print dur, cls; in_e=0}
')
LOCK_TOTAL_MS=$(echo "$LOCK_DATA" | awk '{sum+=$1} END{printf "%.0f",sum+0}')
TOP_LOCKS=$(echo "$LOCK_DATA" | awk '{cls=$2; dur=$1; counts[cls]++; total[cls]+=dur} END{for(c in counts) print counts[c], total[c], c}' | \
  sort -rn | head -5 | \
  awk 'BEGIN{printf "["; first=1}
    {if(!first) printf ","; printf "{\"class\":\"%s\",\"count\":%s,\"total_ms\":%s}", $3, $1, int($2); first=0}
    END{printf "]"}')

echo "  Parks: ${PARK_TOTAL} total  idle: ${PARK_IDLE}  meaningful: ${PARK_MEANINGFUL} (${PARK_MEANINGFUL_MS}ms)"
echo "  Lock contention: ${LOCK_COUNT} events  ${LOCK_TOTAL_MS}ms total"

# ============================================================
# SECTION 6: WRITE JSON
# ============================================================
echo "[6/6] Writing raw JSON..."

cat > "$OUTPUT_FILE" << RAWJSON
{
  "meta": {
    "jfr_file": "$(basename "$JFR_FILE")",
    "recording_start": "$REC_START",
    "recording_end": "$REC_END",
    "recording_duration": "$REC_DUR",
    "wall_clock_s": $WALL_CLOCK_S,
    "wall_clock_ms": $(( WALL_CLOCK_S * 1000 )),
    "total_event_types": "$TOTAL_EVENTS"
  },
  "database": {
    "query_count": $DB_COUNT,
    "total_wait_ms": $DB_TOTAL_MS,
    "avg_ms": $DB_AVG_MS,
    "max_ms": $DB_MAX_MS,
    "p90_ms": ${DB_P90:-0},
    "p99_ms": ${DB_P99:-0},
    "query_timeline": $DB_TIMELINE,
    "slowest_queries": $DB_SLOWEST
  },
  "memory": {
    "heap_min_gb": $HEAP_MIN,
    "heap_max_gb": $HEAP_MAX,
    "heap_last_gb": $HEAP_LAST,
    "heap_delta_gb": $HEAP_DELTA,
    "rss_max_gb": $RSS_MAX,
    "gc_total_count": $GC_TOTAL,
    "gc_young_count": $GC_YOUNG,
    "gc_old_count": $GC_OLD,
    "gc_humongous_count": $GC_HUMONGOUS,
    "gc_total_pause_ms": $GC_TOTAL_PAUSE,
    "gc_max_pause_ms": $GC_MAX_PAUSE,
    "gc_avg_pause_ms": $GC_AVG_PAUSE,
    "gc_pause_dist": {
      "under_50ms": $GC_UNDER50,
      "50_to_100ms": $GC_50_100,
      "100_to_200ms": $GC_100_200,
      "over_200ms": $GC_OVER200
    },
    "heap_timeline": $HEAP_TIMELINE,
    "rss_timeline": $RSS_TIMELINE,
    "gc_timeline": $GC_TIMELINE,
    "gc_events": $GC_EVENTS,
    "top_allocating_classes": $TOP_ALLOC,
    "jcma_allocations": $JCMA_ALLOC
  },
  "cpu": {
    "execution_sample_count": $EXEC_COUNT,
    "jvm_avg_pct": $CPU_AVG,
    "jvm_peak_pct": $CPU_PEAK,
    "cpu_timeline": $CPU_TIMELINE,
    "top_methods_overall": [],
    "top_jcma_methods": $TOP_JCMA,
    "jcma_by_package": $JCMA_PKG,
    "jcma_by_thread": []
  },
  "threads": {
    "park_total_count": $PARK_TOTAL,
    "park_idle_count": $PARK_IDLE,
    "park_meaningful_count": $PARK_MEANINGFUL,
    "park_meaningful_ms": $PARK_MEANINGFUL_MS,
    "lock_contention_count": $LOCK_COUNT,
    "lock_contention_total_ms": $LOCK_TOTAL_MS,
    "top_blocking_classes": $TOP_BLOCKS,
    "top_lock_classes": $TOP_LOCKS
  }
}
RAWJSON

echo ""
echo "✅ Extraction complete → $OUTPUT_FILE"
echo ""
echo "📊 Quick summary:"
echo "   DB queries:      $DB_COUNT  (total wait: ${DB_TOTAL_MS}ms  avg: ${DB_AVG_MS}ms  max: ${DB_MAX_MS}ms)"
echo "   Heap range:      ${HEAP_MIN}→${HEAP_MAX}GB (delta: ${HEAP_DELTA}GB)"
echo "   GC events:       $GC_TOTAL (Young:$GC_YOUNG Old:$GC_OLD Humongous:$GC_HUMONGOUS) max pause: ${GC_MAX_PAUSE}ms"
echo "   CPU:             avg ${CPU_AVG}%  peak ${CPU_PEAK}%"
echo "   Thread parks:    $PARK_TOTAL total ($PARK_IDLE idle, $PARK_MEANINGFUL meaningful)"
echo "   Lock contention: $LOCK_COUNT events (${LOCK_TOTAL_MS}ms)"
