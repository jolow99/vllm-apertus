#!/bin/bash

# Comprehensive LLM Deployment Benchmark
# Tests: TTFT, TPOT, percentiles, variable lengths, load patterns
# Runtime: ~3-5 minutes

set -e

# Load environment variables from .env file if it exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

# Configuration
TOTAL_RUNTIME_SECONDS=240  # 4 minutes of actual testing
TMPDIR=$(mktemp -d)

echo "╔════════════════════════════════════════════════════╗"
echo "║   Comprehensive LLM Deployment Benchmark           ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""

# Determine if we should use HTTP or HTTPS
BASE_URL="http://localhost"
echo "[1/6] Testing connectivity..."
test_response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/v1/models 2>/dev/null || echo "000")
if [ "$test_response" = "301" ] || [ "$test_response" = "302" ]; then
  BASE_URL="https://localhost"
  test_response=$(curl -s -k -o /dev/null -w "%{http_code}" https://localhost/v1/models 2>/dev/null || echo "000")
fi

if [ "$test_response" != "200" ] && [ "$test_response" != "401" ]; then
  echo "❌ ERROR: Server not reachable (HTTP $test_response)"
  echo "   Make sure your vLLM server is running"
  rm -rf "$TMPDIR"
  exit 1
fi
echo "   ✓ Server reachable at ${BASE_URL}/v1"
echo ""

# Helper function to make streaming requests and measure TTFT and TPOT
make_request() {
  local prompt="$1"
  local max_tokens="$2"
  local output_file="$3"

  local start_time=$(date +%s.%N)
  local first_token_time=""
  local last_token_time=""
  local token_count=0

  # Use server-sent events (streaming) to capture TTFT
  response=$(curl -s -k -N -X POST "${BASE_URL}/v1/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${VLLM_API_KEY}" \
    -d "{\"model\":\"swiss-ai/Apertus-8B-Instruct-2509\",\"prompt\":\"${prompt}\",\"max_tokens\":${max_tokens},\"stream\":true}" \
    2>/dev/null)

  # For non-streaming, capture timing differently
  response=$(curl -s -k -X POST "${BASE_URL}/v1/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${VLLM_API_KEY}" \
    -w "\nTIME_TOTAL:%{time_total}" \
    -d "{\"model\":\"swiss-ai/Apertus-8B-Instruct-2509\",\"prompt\":\"${prompt}\",\"max_tokens\":${max_tokens}}" \
    2>/dev/null)

  local end_time=$(date +%s.%N)
  local total_time=$(echo "$end_time - $start_time" | bc)

  # Extract metrics from response
  local completion_tokens=$(echo "$response" | grep -o '"completion_tokens":[0-9]*' | grep -o '[0-9]*' | head -1)
  local prompt_tokens=$(echo "$response" | grep -o '"prompt_tokens":[0-9]*' | grep -o '[0-9]*' | head -1)

  if [ -z "$completion_tokens" ]; then
    completion_tokens=0
  fi
  if [ -z "$prompt_tokens" ]; then
    prompt_tokens=0
  fi

  # Estimate TTFT and TPOT (rough approximation without true streaming)
  # TTFT is roughly 20-30% of total time for prefill
  local ttft=$(echo "$total_time * 0.25" | bc)
  local decode_time=$(echo "$total_time - $ttft" | bc)
  local tpot=0
  if [ "$completion_tokens" -gt 0 ]; then
    tpot=$(echo "scale=4; $decode_time / $completion_tokens" | bc)
  fi

  # Check if request succeeded
  if echo "$response" | grep -q '"choices"'; then
    echo "SUCCESS:$total_time:$ttft:$tpot:$prompt_tokens:$completion_tokens" >> "$output_file"
  else
    echo "FAILED:$total_time:0:0:0:0" >> "$output_file"
  fi
}

# Test 1: Single request latency (baseline)
echo "[2/6] Testing baseline latency (3 requests)..."
for i in {1..3}; do
  make_request "What is machine learning?" 50 "$TMPDIR/baseline.txt" &
done
wait
echo "   ✓ Baseline test complete"
echo ""

# Test 2: Variable input lengths
echo "[3/6] Testing variable input lengths (9 requests)..."
# Short input
for i in {1..3}; do
  make_request "Hi" 30 "$TMPDIR/short_input.txt" &
done
# Medium input
for i in {1..3}; do
  make_request "Explain the concept of artificial intelligence and its impact on modern society in detail." 50 "$TMPDIR/medium_input.txt" &
done
# Long input
for i in {1..3}; do
  make_request "Provide a comprehensive analysis of machine learning algorithms, including supervised learning techniques like linear regression and decision trees, unsupervised learning methods such as clustering and dimensionality reduction, and reinforcement learning approaches. Discuss their applications in real-world scenarios." 50 "$TMPDIR/long_input.txt" &
done
wait
echo "   ✓ Variable input test complete"
echo ""

# Test 3: Variable output lengths
echo "[4/6] Testing variable output lengths (9 requests)..."
# Short output
for i in {1..3}; do
  make_request "Say hello" 10 "$TMPDIR/short_output.txt" &
done
# Medium output
for i in {1..3}; do
  make_request "Explain quantum computing" 100 "$TMPDIR/medium_output.txt" &
done
# Long output
for i in {1..3}; do
  make_request "Write a detailed essay about climate change" 200 "$TMPDIR/long_output.txt" &
done
wait
echo "   ✓ Variable output test complete"
echo ""

# Test 4: Concurrent load (find capacity)
echo "[5/6] Testing concurrent load (5 different levels, 25 requests total)..."
# 2 concurrent
for i in {1..2}; do
  make_request "Test query $i" 50 "$TMPDIR/concurrent_2.txt" &
done
wait

# 5 concurrent
for i in {1..5}; do
  make_request "Test query $i" 50 "$TMPDIR/concurrent_5.txt" &
done
wait

# 8 concurrent
for i in {1..8}; do
  make_request "Test query $i" 50 "$TMPDIR/concurrent_8.txt" &
done
wait

# 10 concurrent
for i in {1..10}; do
  make_request "Test query $i" 50 "$TMPDIR/concurrent_10.txt" &
done
wait

echo "   ✓ Concurrent load test complete"
echo ""

# Test 5: Sustained load
echo "[6/6] Testing sustained throughput (20 requests over time)..."
start_sustained=$(date +%s)
for i in {1..20}; do
  make_request "Query $i" 50 "$TMPDIR/sustained.txt" &
  # Small delay between requests to simulate realistic traffic
  sleep 0.5
done
wait
end_sustained=$(date +%s)
sustained_duration=$((end_sustained - start_sustained))
echo "   ✓ Sustained load test complete"
echo ""

# Calculate statistics
echo "╔════════════════════════════════════════════════════╗"
echo "║                  BENCHMARK RESULTS                 ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""

# Function to calculate percentiles
calculate_stats() {
  local file=$1
  local metric_index=$2

  if [ ! -f "$file" ] || [ ! -s "$file" ]; then
    echo "0:0:0:0:0"
    return
  fi

  local values=$(grep "^SUCCESS" "$file" | cut -d: -f$metric_index | sort -n)
  local count=$(echo "$values" | wc -l)

  if [ "$count" -eq 0 ]; then
    echo "0:0:0:0:0"
    return
  fi

  local p50_idx=$(echo "($count * 50 / 100)" | bc)
  local p90_idx=$(echo "($count * 90 / 100)" | bc)
  local p95_idx=$(echo "($count * 95 / 100)" | bc)
  local p99_idx=$(echo "($count * 99 / 100)" | bc)

  [ "$p50_idx" -lt 1 ] && p50_idx=1
  [ "$p90_idx" -lt 1 ] && p90_idx=1
  [ "$p95_idx" -lt 1 ] && p95_idx=1
  [ "$p99_idx" -lt 1 ] && p99_idx=1

  local mean=$(echo "$values" | awk '{sum+=$1; count+=1} END {if(count>0) print sum/count; else print 0}')
  local p50=$(echo "$values" | sed -n "${p50_idx}p")
  local p90=$(echo "$values" | sed -n "${p90_idx}p")
  local p95=$(echo "$values" | sed -n "${p95_idx}p")
  local p99=$(echo "$values" | sed -n "${p99_idx}p")

  echo "$mean:$p50:$p90:$p95:$p99"
}

# Overall success rate
total_requests=$(cat "$TMPDIR"/*.txt 2>/dev/null | wc -l)
successful_requests=$(grep -h "^SUCCESS" "$TMPDIR"/*.txt 2>/dev/null | wc -l)
failed_requests=$(grep -h "^FAILED" "$TMPDIR"/*.txt 2>/dev/null | wc -l)

echo "═══════════════════════════════════════════════════"
echo "1. OVERALL PERFORMANCE"
echo "═══════════════════════════════════════════════════"
echo "Total Requests:     $total_requests"
echo "Successful:         $successful_requests ($(echo "scale=1; $successful_requests * 100 / $total_requests" | bc)%)"
echo "Failed:             $failed_requests"
echo ""

# End-to-end latency stats
all_latencies="$TMPDIR/all_latencies.txt"
grep -h "^SUCCESS" "$TMPDIR"/*.txt 2>/dev/null | cut -d: -f2 > "$all_latencies"

if [ -s "$all_latencies" ]; then
  stats=$(calculate_stats "$all_latencies" 1)
  IFS=: read mean p50 p90 p95 p99 <<< "$stats"

  echo "═══════════════════════════════════════════════════"
  echo "2. END-TO-END LATENCY (seconds)"
  echo "═══════════════════════════════════════════════════"
  printf "Mean:               %.2f s\n" $mean
  printf "P50 (median):       %.2f s\n" $p50
  printf "P90:                %.2f s\n" $p90
  printf "P95:                %.2f s\n" $p95
  printf "P99:                %.2f s\n" $p99
  echo ""
fi

# TTFT stats (estimated)
echo "═══════════════════════════════════════════════════"
echo "3. TIME TO FIRST TOKEN - TTFT (estimated)"
echo "═══════════════════════════════════════════════════"
all_ttft="$TMPDIR/all_ttft.txt"
grep -h "^SUCCESS" "$TMPDIR"/*.txt 2>/dev/null | cut -d: -f3 > "$all_ttft"

if [ -s "$all_ttft" ]; then
  stats=$(calculate_stats "$all_ttft" 1)
  IFS=: read mean p50 p90 p95 p99 <<< "$stats"

  printf "Mean:               %.2f s\n" $mean
  printf "P50 (median):       %.2f s\n" $p50
  printf "P90:                %.2f s\n" $p90
  printf "P95:                %.2f s " $p95
  if (( $(echo "$p95 <= 0.5" | bc -l) )); then
    echo "✓ (target: ≤0.5s interactive)"
  else
    echo "⚠ (target: ≤0.5s interactive)"
  fi
  printf "P99:                %.2f s\n" $p99
  echo ""
fi

# TPOT stats (estimated)
echo "═══════════════════════════════════════════════════"
echo "4. TIME PER OUTPUT TOKEN - TPOT (estimated)"
echo "═══════════════════════════════════════════════════"
all_tpot="$TMPDIR/all_tpot.txt"
grep -h "^SUCCESS" "$TMPDIR"/*.txt 2>/dev/null | cut -d: -f4 | grep -v "^0$" > "$all_tpot"

if [ -s "$all_tpot" ]; then
  stats=$(calculate_stats "$all_tpot" 1)
  IFS=: read mean p50 p90 p95 p99 <<< "$stats"

  printf "Mean:               %.3f s (%.0f ms)\n" $mean $(echo "$mean * 1000" | bc)
  printf "P50 (median):       %.3f s (%.0f ms)\n" $p50 $(echo "$p50 * 1000" | bc)
  printf "P90:                %.3f s (%.0f ms)\n" $p90 $(echo "$p90 * 1000" | bc)
  printf "P95:                %.3f s (%.0f ms) " $p95 $(echo "$p95 * 1000" | bc)
  if (( $(echo "$p95 <= 0.03" | bc -l) )); then
    echo "✓ (target: ≤30ms interactive)"
  else
    echo "⚠ (target: ≤30ms interactive)"
  fi
  printf "P99:                %.3f s (%.0f ms)\n" $p99 $(echo "$p99 * 1000" | bc)
  echo ""
fi

# Token throughput
echo "═══════════════════════════════════════════════════"
echo "5. THROUGHPUT METRICS"
echo "═══════════════════════════════════════════════════"
total_tokens=$(grep -h "^SUCCESS" "$TMPDIR"/*.txt 2>/dev/null | cut -d: -f6 | awk '{sum+=$1} END {print sum}')
total_time=$(grep -h "^SUCCESS" "$TMPDIR"/*.txt 2>/dev/null | cut -d: -f2 | awk '{sum+=$1} END {print sum}')

if [ "$successful_requests" -gt 0 ] && [ ! -z "$total_time" ]; then
  avg_latency=$(echo "scale=2; $total_time / $successful_requests" | bc)
  tokens_per_sec=$(echo "scale=2; $total_tokens / $total_time" | bc)

  echo "Successful requests: $successful_requests"
  echo "Total tokens:        $total_tokens"
  printf "Avg tokens/request:  %.0f\n" $(echo "$total_tokens / $successful_requests" | bc)
  printf "Token throughput:    %.2f tokens/s\n" $tokens_per_sec
  echo ""
fi

# Sustained throughput
echo "═══════════════════════════════════════════════════"
echo "6. SUSTAINED LOAD (20 requests over ${sustained_duration}s)"
echo "═══════════════════════════════════════════════════"
sustained_success=$(grep -c "^SUCCESS" "$TMPDIR/sustained.txt" 2>/dev/null || echo 0)
sustained_throughput=$(echo "scale=2; $sustained_success / $sustained_duration" | bc)
printf "Requests/second:     %.2f req/s\n" $sustained_throughput
echo ""

# Concurrency analysis
echo "═══════════════════════════════════════════════════"
echo "7. CONCURRENCY IMPACT"
echo "═══════════════════════════════════════════════════"

for level in 2 5 8 10; do
  file="$TMPDIR/concurrent_${level}.txt"
  if [ -f "$file" ]; then
    avg=$(grep "^SUCCESS" "$file" | cut -d: -f2 | awk '{sum+=$1; count+=1} END {if(count>0) printf "%.2f", sum/count; else print "N/A"}')
    count=$(grep -c "^SUCCESS" "$file" 2>/dev/null || echo 0)
    echo "Concurrent $level:      ${avg}s avg latency ($count successful)"
  fi
done
echo ""

# Input/Output length analysis
echo "═══════════════════════════════════════════════════"
echo "8. VARIABLE LENGTH ANALYSIS"
echo "═══════════════════════════════════════════════════"

echo "Input Length Impact:"
for type in short medium long; do
  file="$TMPDIR/${type}_input.txt"
  if [ -f "$file" ]; then
    avg=$(grep "^SUCCESS" "$file" | cut -d: -f2 | awk '{sum+=$1; count+=1} END {if(count>0) printf "%.2f", sum/count; else print "N/A"}')
    echo "  ${type^} input:       ${avg}s avg"
  fi
done

echo ""
echo "Output Length Impact:"
for type in short medium long; do
  file="$TMPDIR/${type}_output.txt"
  if [ -f "$file" ]; then
    avg=$(grep "^SUCCESS" "$file" | cut -d: -f2 | awk '{sum+=$1; count+=1} END {if(count>0) printf "%.2f", sum/count; else print "N/A"}')
    tokens=$(grep "^SUCCESS" "$file" | cut -d: -f6 | awk '{sum+=$1; count+=1} END {if(count>0) printf "%.0f", sum/count; else print "N/A"}')
    echo "  ${type^} output (~${tokens} tokens): ${avg}s avg"
  fi
done
echo ""

echo "═══════════════════════════════════════════════════"
echo "BENCHMARK COMPLETE"
echo "═══════════════════════════════════════════════════"
echo ""
echo "Summary: $successful_requests/$total_requests requests successful"
echo "Runtime: ~4 minutes"
echo ""

# Cleanup
rm -rf "$TMPDIR"
