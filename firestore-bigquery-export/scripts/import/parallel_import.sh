#!/bin/bash

# This script imports all Firestore collections to BigQuery
# using parallel processing and logs results

# Text formatting
BOLD="\033[1m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# Configuration
PROJECT="deephow-dev"
BQ_PROJECT="deephow-dev"
DATASET="tmp"
DATASET_LOCATION="us"
BATCH_SIZE=3000
RESULTS_FILE="import_results.json"
LOG_DIR="import_logs"
MAX_PARALLEL=10  # Based on M4 CPU cores (12), leaving some for system
TEST_MODE=false  # Set to true to test without actually importing
INPUT_FILE="firestore_counts.json"

# Default values for statistics
TOTAL_IMPORTED=0
SUCCESSFUL=0
FAILED=0
TOTAL_DURATION=0

# Process command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --test)
      TEST_MODE=true
      shift
      ;;
    --parallel=*)
      MAX_PARALLEL="${1#*=}"
      shift
      ;;
    --batch-size=*)
      BATCH_SIZE="${1#*=}"
      shift
      ;;
    --input=*)
      INPUT_FILE="${1#*=}"
      shift
      ;;
    *)
      echo -e "${RED}Unknown option: $1${RESET}"
      echo "Usage: $0 [--test] [--parallel=N] [--batch-size=N] [--input=FILE]"
      exit 1
      ;;
  esac
done

# Display banner
echo -e "${BOLD}${BLUE}"
echo "==============================================================="
echo "  FIRESTORE TO BIGQUERY IMPORT UTILITY"
echo "==============================================================="
echo -e "${RESET}"
echo -e "Project: ${BOLD}$PROJECT${RESET}"
echo -e "Dataset: ${BOLD}$DATASET${RESET}"
echo -e "Parallel processes: ${BOLD}$MAX_PARALLEL${RESET}"
echo -e "Batch size: ${BOLD}$BATCH_SIZE${RESET}"
echo -e "Input file: ${BOLD}$INPUT_FILE${RESET}"
if [ "$TEST_MODE" = true ]; then
  echo -e "${YELLOW}TEST MODE: No actual imports will be performed${RESET}"
fi
echo ""

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Clear existing result files if any
rm -f "$LOG_DIR"/*_result.json 2>/dev/null
rm -f "$LOG_DIR"/*_result.txt 2>/dev/null

# Check for input file
if [ ! -f "$INPUT_FILE" ]; then
  echo -e "${RED}Error: $INPUT_FILE not found${RESET}"
  exit 1
fi

# Store collections in arrays
COLLECTIONS=()
COLLECTION_NAMES=()
COLLECTION_COUNTS=()

# Parse collection data from the new JSON format
while read -r line; do
  if [[ ! -z "$line" ]]; then
    # Skip collections with error status
    status=$(echo "$line" | jq -r '.status')
    if [ "$status" = "error" ]; then
      collection=$(echo "$line" | jq -r '.collection')
      echo -e "${YELLOW}Skipping collection '$collection' due to error status in input file${RESET}"
      continue
    fi
    
    COLLECTIONS+=("$line")
    collection=$(echo "$line" | jq -r '.collection')
    count=$(echo "$line" | jq -r '.count')
    
    COLLECTION_NAMES+=("$collection")
    COLLECTION_COUNTS+=($count)
  fi
done < <(jq -c '.collections[]' "$INPUT_FILE")

TOTAL_COLLECTIONS=${#COLLECTIONS[@]}
CURRENT=0

if [ $TOTAL_COLLECTIONS -eq 0 ]; then
  echo -e "${RED}Error: No valid collections found in $INPUT_FILE${RESET}"
  exit 1
fi

echo -e "Found ${BOLD}$TOTAL_COLLECTIONS${RESET} collections to import"

# Function to import a collection
import_collection() {
  local index=$1
  local collection="${COLLECTION_NAMES[$index]}"
  local count="${COLLECTION_COUNTS[$index]}"
  
  # Generate prefix by converting collection name to lowercase and replacing non-alphanumeric chars with underscore
  local prefix=$(echo "$collection" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
  
  # Create log file for this collection
  local log_file="$LOG_DIR/${prefix}_import.log"
  
  echo -e "${BOLD}Importing collection:${RESET} $collection (Expected count: $count)"
  
  local start_time=$(date +%s)
  local imported_count=0
  local status=0
  
  # Run the import command (or simulate in test mode)
  if [ "$TEST_MODE" = true ]; then
    # Simulate import in test mode
    echo "TEST MODE: Would import collection $collection with prefix $prefix" > "$log_file"
    sleep 2  # Simulate short processing time
    imported_count=$count
  else
    # Actual import
    npx @firebaseextensions/fs-bq-import-collection \
      --non-interactive \
      --project="$PROJECT" \
      --big-query-project="$BQ_PROJECT" \
      --source-collection-path="$collection" \
      --query-collection-group=false \
      --dataset="$DATASET" \
      --table-name-prefix="$prefix" \
      --batch-size="$BATCH_SIZE" \
      --dataset-location="$DATASET_LOCATION" \
      --multi-threaded=true \
      --use-new-snapshot-query-syntax=true \
      --transform-function-url="" \
      --use-emulator=false \
      --failed-batch-output="" > "$log_file" 2>&1
    
    # Get import status
    status=$?
    
    # Extract the actual imported count
    imported_count=$(grep -o "Finished importing [0-9]* Firestore rows to BigQuery" "$log_file" | grep -o "[0-9]*")
    
    if [ -z "$imported_count" ]; then
      imported_count=0
    fi
  fi
  
  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  
  # Save results to a simple plain text file
  echo "$collection|$prefix|$count|$imported_count|$status|$duration" > "$LOG_DIR/${prefix}_result.txt"
  
  if [ $status -eq 0 ]; then
    echo -e "Finished ${GREEN}$collection${RESET} (Status: ${GREEN}Success${RESET}, Imported: $imported_count, Time: ${duration}s)"
  else
    echo -e "Finished ${RED}$collection${RESET} (Status: ${RED}Failed${RESET}, Imported: $imported_count, Time: ${duration}s)"
  fi
}

# Process collections using parallel
echo -e "${BOLD}Starting parallel import of $TOTAL_COLLECTIONS collections (max $MAX_PARALLEL processes)${RESET}"
echo ""

# Setup a temporary FIFO for parallel processing
FIFO=$(mktemp -u)
mkfifo "$FIFO"

# Start background process to read from FIFO
exec 3<>"$FIFO"
rm "$FIFO"

# Initialize semaphore
for ((i=0; i<MAX_PARALLEL; i++)); do
  echo >&3
done

# Process collections
for ((i=0; i<TOTAL_COLLECTIONS; i++)); do
  # Wait for a slot
  read -u 3
  
  # Process this collection in background
  {
    import_collection "$i"
    # Signal that a slot is free
    echo >&3
  } &
  
  CURRENT=$((CURRENT + 1))
  echo -e "${BLUE}[$CURRENT/$TOTAL_COLLECTIONS]${RESET} Queued collection for import"
done

# Wait for all background jobs to finish
echo -e "\n${YELLOW}Waiting for all imports to complete...${RESET}"
wait

# Close the FIFO
exec 3>&-

echo -e "\n${GREEN}All imports completed! Processing results...${RESET}\n"

# Collect results and build JSON manually
echo "{" > "$RESULTS_FILE"
echo "  \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"," >> "$RESULTS_FILE"
echo "  \"test_mode\": $TEST_MODE," >> "$RESULTS_FILE"
echo "  \"collections\": [" >> "$RESULTS_FILE"

# Process results from simple text files
RESULT_FILES=("$LOG_DIR"/*_result.txt)
RESULT_COUNT=${#RESULT_FILES[@]}

for ((i=0; i<RESULT_COUNT; i++)); do
  result_file="${RESULT_FILES[$i]}"
  if [ -f "$result_file" ]; then
    # Read pipe-delimited data
    IFS='|' read -r collection prefix expected_count imported_count status duration < "$result_file"
    
    # Write to JSON
    echo "    {" >> "$RESULTS_FILE"
    echo "      \"collection\": \"$collection\"," >> "$RESULTS_FILE"
    echo "      \"prefix\": \"$prefix\"," >> "$RESULTS_FILE"
    echo "      \"expected_count\": $expected_count," >> "$RESULTS_FILE"
    echo "      \"imported_count\": $imported_count," >> "$RESULTS_FILE"
    echo "      \"status\": $status," >> "$RESULTS_FILE"
    echo "      \"duration_seconds\": $duration" >> "$RESULTS_FILE"
    echo -n "    }" >> "$RESULTS_FILE"
    
    # Add comma after all but the last item
    if [ $i -lt $((RESULT_COUNT-1)) ]; then
      echo "," >> "$RESULTS_FILE"
    else
      echo "" >> "$RESULTS_FILE"
    fi
    
    # Calculate statistics
    TOTAL_IMPORTED=$((TOTAL_IMPORTED + imported_count))
    TOTAL_DURATION=$((TOTAL_DURATION + duration))
    if [ "$status" -eq 0 ]; then
      SUCCESSFUL=$((SUCCESSFUL + 1))
    else
      FAILED=$((FAILED + 1))
    fi
  fi
done

# Finalize results JSON
echo "  ]," >> "$RESULTS_FILE"

# Add summary section
echo "  \"summary\": {" >> "$RESULTS_FILE"
echo "    \"total_collections\": $TOTAL_COLLECTIONS," >> "$RESULTS_FILE"
echo "    \"successful\": $SUCCESSFUL," >> "$RESULTS_FILE"
echo "    \"failed\": $FAILED," >> "$RESULTS_FILE"
echo "    \"total_imported_records\": $TOTAL_IMPORTED," >> "$RESULTS_FILE"
echo "    \"total_duration_seconds\": $TOTAL_DURATION," >> "$RESULTS_FILE"
echo "    \"completed_at\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"" >> "$RESULTS_FILE"
echo "  }" >> "$RESULTS_FILE"
echo "}" >> "$RESULTS_FILE"

# Generate a human-readable summary
echo -e "${BOLD}${BLUE}=================================================="
echo "                IMPORT SUMMARY                   "
echo -e "==================================================${RESET}"
echo -e "Total collections processed: ${BOLD}$TOTAL_COLLECTIONS${RESET}"
echo -e "Successful imports: ${GREEN}${BOLD}$SUCCESSFUL${RESET}"
echo -e "Failed imports: ${RED}${BOLD}$FAILED${RESET}"
echo -e "Total imported records: ${BOLD}$TOTAL_IMPORTED${RESET}"
echo -e "Total processing time: ${BOLD}$TOTAL_DURATION seconds${RESET}"
echo -e "${BLUE}=================================================="
echo -e "${RESET}Detailed results saved to ${BOLD}$RESULTS_FILE${RESET}"
echo -e "Individual logs saved to ${BOLD}$LOG_DIR${RESET} directory"

# Create a simple markdown report
{
  echo "# Firestore to BigQuery Import Summary"
  echo ""
  echo "## Overview"
  echo "- **Timestamp:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  echo "- **Total Collections:** $TOTAL_COLLECTIONS"
  echo "- **Successful Imports:** $SUCCESSFUL"
  echo "- **Failed Imports:** $FAILED"
  echo "- **Total Records Imported:** $TOTAL_IMPORTED"
  echo "- **Total Processing Time:** $TOTAL_DURATION seconds"
  echo "- **Test Mode:** $TEST_MODE"
  echo ""
  echo "## Collection Details"
  echo ""
  echo "| Collection | Prefix | Expected Count | Imported Count | Duration (s) | Status |"
  echo "|------------|--------|---------------|----------------|--------------|--------|"
  
  # Generate table rows from the result files
  for result_file in "$LOG_DIR"/*_result.txt; do
    if [ -f "$result_file" ]; then
      IFS='|' read -r collection prefix expected_count imported_count status duration < "$result_file"
      if [ "$status" -eq 0 ]; then
        status_text="✅ Success"
      else
        status_text="❌ Failed"
      fi
      echo "| $collection | $prefix | $expected_count | $imported_count | $duration | $status_text |"
    fi
  done
  
  echo ""
  echo "## Notes"
  echo "- Logs for each import are available in the \`$LOG_DIR\` directory"
  echo "- Full JSON results are in \`$RESULTS_FILE\`"
} > "import_summary.md"

echo -e "\nSummary markdown report saved to ${BOLD}import_summary.md${RESET}"

# Print failures if any
if [ "$FAILED" -gt 0 ]; then
  echo -e "\n${RED}${BOLD}WARNING: Some imports failed. Failed collections:${RESET}"
  
  # List failed collections directly from result files
  for result_file in "$LOG_DIR"/*_result.txt; do
    if [ -f "$result_file" ]; then
      IFS='|' read -r collection prefix expected_count imported_count status duration < "$result_file"
      if [ "$status" -ne 0 ]; then
        echo -e "  - ${RED}$collection${RESET}"
      fi
    fi
  done
  
  echo -e "${YELLOW}Check the log files in $LOG_DIR for details${RESET}"
fi