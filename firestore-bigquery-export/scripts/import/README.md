The `fs-bq-import-collection` script is for use with the official Firebase Extension [_Stream Firestore to BigQuery_](https://github.com/firebase/extensions/tree/master/firestore-bigquery-export).

This script reads all existing documents in a specified Firestore Collection, and updates the changelog table used by the `firestore-bigquery-export` extension.

A guide on how to use the script can be found [here](https://github.com/firebase/extensions/blob/master/firestore-bigquery-export/guides/IMPORT_EXISTING_DOCUMENTS.md).

Also, please follow the instruction below to fit Daduo-developed import progress.

# Step 1: 確認 BigQuery 當前資料

## 前置準備步驟

1. 設定 Service Account
   - 將 service account 的 JSON 檔案放在 `scripts/import/<service-account.json>` 位置
   - 重新命名為 `service-account.json`

2. 設定執行權限
   ```bash
   chmod +x bq_tables_pre_import.sh
   ```

3. 執行前檢查
   - 確認 `PROJECT_ID` 和 `DATASET` 設定正確
   - 確認 service account 有足夠的權限存取 BigQuery

4. 執行腳本
   ```bash
   ./bq_tables_pre_import.sh
   ```

腳本執行後會產生 `bq_tables_count_pre_import.json` 檔案，記錄每個表格的資料筆數。

# Step 2: 計算 Firestore 集合中的文檔數量

## 前置準備

1. 確保已安裝必要的 Python 套件：
   ```bash
   pip install firebase-admin
   ```

2. 確認 `GOOGLE_APPLICATION_CREDENTIALS` 環境變數已設定：
   ```bash
   export GOOGLE_APPLICATION_CREDENTIALS=service-account.json
   ```

## 執行腳本

1. 基本執行：
   ```bash
   python firestore_tables_pre_import.py
   ```

2. 可選參數：
   - `--output`: 指定輸出檔案名稱（預設為 'firestore_counts'）
   - `--timeout`: 設定每個集合的超時時間（秒）（預設為 120 秒）
   
   例如：
   ```bash
   python firestore_tables_pre_import.py --output my_counts --timeout 180
   ```

## 輸出結果

腳本會產生兩個檔案：
1. `<output>.json`: 包含詳細的統計資料
2. `<output>.md`: 格式化的 Markdown 報告

報告內容包括：
- 總集合數
- 成功統計的集合數
- 統計失敗的集合數
- 總文檔數
- 總處理時間
- 每個集合的詳細統計（記錄數量、處理時間、狀態）

## 注意事項

1. 腳本會處理以下集合，如果遇到錯誤，請確認 firestore 內的 collection name 是否吻合：
   - addons
   - ai_summary
   - annotations
   - businesses
   - categories
   - groups
   - groups_delete
   - multimodal_sop
   - multimodal_sop_delete
   - multimodal_sop_tracking
   - organizations
   - playlists
   - quizzes
   - teams
   - teamSkills
   - tracking
   - users
   - usersSkillCertificates
   - usersSkills
   - usersQuizzes
   - workflows
   - workflows_delete
   - workflows_reactions
   - workflows_version_histories
   - workspaces_groups

2. 如果遇到超時錯誤，可以增加 `--timeout` 參數的值
3. 確保 service account 有足夠的權限存取 Firestore

# Step 3: 平行匯入 Firestore 資料到 BigQuery

## 前置準備

1. 確保已安裝必要的套件：
   ```bash
   npm install @firebaseextensions/fs-bq-import-collection
   ```

2. 確認 `GOOGLE_APPLICATION_CREDENTIALS` 環境變數已設定：
   ```bash
   export GOOGLE_APPLICATION_CREDENTIALS=service-account.json
   ```

## 測試環境

1. 可以透過交互式的介面，測試其中一個 collection 是否會順利運行
    ```bash
    npx @firebaseextensions/fs-bq-import-collection
    ```

## 執行腳本

1. 基本執行：
   ```bash
   chmod +x parallel_import.sh
   ```

   ```bash
   ./parallel_import.sh
   ```

2. 可選參數：
   - `--parallel=N`: 設定平行處理數量（預設為 10）
   - `--batch-size=N`: 設定批次大小（預設為 3000）
   - `--input=FILE`: 指定輸入檔案（預設為 'firestore_counts.json'）
   
   例如：
   ```bash
   ./parallel_import.sh --parallel=5 --batch-size=5000 --input=my_counts.json
   ```

## 輸出結果

腳本會產生以下檔案：
1. `import_results.json`: 包含詳細的匯入結果
2. `import_summary.md`: 格式化的 Markdown 報告
3. `import_logs/`: 目錄，包含每個集合的詳細日誌

報告內容包括：
- 總處理的集合數
- 成功匯入的集合數
- 失敗的集合數
- 總匯入的記錄數
- 總處理時間
- 每個集合的詳細統計（預期數量、實際匯入數量、處理時間、狀態）

## 注意事項

1. 預設設定：
   - 專案：deephow-dev
   - BigQuery 專案：deephow-dev
   - 資料集：tmp
   - 資料集位置：us
   - 最大平行處理數：10
   - 批次大小：3000

2. 執行建議：
   - 根據系統資源調整 `--parallel` 參數
   - 如果遇到記憶體問題，可以減少 `--batch-size`
   - 確保 service account 有足夠的權限存取 Firestore 和 BigQuery

3. 錯誤處理：
   - 失敗的匯入會記錄在 `import_logs/` 目錄中
   - 可以查看對應的日誌檔案了解詳細錯誤原因
   - 匯入失敗的集合會在最後的總結中特別標示 