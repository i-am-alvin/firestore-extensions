#!/bin/bash

# Set the path to your service account key file
export GOOGLE_APPLICATION_CREDENTIALS="service-account.json"

PROJECT_ID="deephow-dev"
DATASET="firebase"
OUTPUT_FILE="bq_tables_count_pre_import.json"

echo "[" > $OUTPUT_FILE
total_tables=$(bq ls -n 1000 $PROJECT_ID:$DATASET | grep "_raw_latest" | wc -l)
echo "Found $total_tables tables to process in $PROJECT_ID.$DATASET"

current=0
for table in $(bq ls -n 1000 $PROJECT_ID:$DATASET | grep "_raw_latest" | awk '{print $1}'); do
  current=$((current + 1))
  echo "[$current/$total_tables] Processing table: $table"
  
  count=$(bq query --use_legacy_sql=false --quiet --format=csv "SELECT COUNT(*) FROM \`$PROJECT_ID.$DATASET.$table\`" | tail -n 1)
  echo "  - Row count: $count"
  
  if [ -s $OUTPUT_FILE ] && [ "$(tail -c 2 $OUTPUT_FILE)" != "[" ]; then
    echo "," >> $OUTPUT_FILE
  fi
  echo "  {" >> $OUTPUT_FILE
  echo "    \"table_name\": \"$table\"," >> $OUTPUT_FILE
  echo "    \"row_count\": $count" >> $OUTPUT_FILE
  echo "  }" >> $OUTPUT_FILE
  
  percent=$((current * 100 / total_tables))
  echo "Progress: $percent% complete"
  echo "----------------------------------------"
done

echo "]" >> $OUTPUT_FILE
echo "All done! Results saved to $OUTPUT_FILE"