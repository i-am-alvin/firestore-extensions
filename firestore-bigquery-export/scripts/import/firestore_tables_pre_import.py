import firebase_admin
from firebase_admin import credentials
from firebase_admin import firestore
import json
import time
import os
import sys
from datetime import datetime
import argparse

# List of collections to count
# 使用原始 collection name 而非 BQ name
COLLECTIONS = [
    "addons",
    "ai_summary",
    "annotations",
    "businesses",
    "categories",
    "groups",
    "groups_delete",
    "multimodal_sop",
    "multimodal_sop_delete",
    "multimodal_sop_tracking",
    "organizations",
    "playlists",
    "quizzes",
    "teams",
    "teamSkills",
    "tracking",
    "users",
    "usersSkillCertificates",
    "usersSkills",
    "usersQuizzes",
    "workflows",
    "workflows_delete",
    "workflows_reactions",
    "workflows_version_histories",
    "workspaces_groups"
]

def init_firebase_app():
    """
    初始化 Firebase 應用程序
    """
    try:
        # 檢查是否設置了環境變量
        if 'GOOGLE_APPLICATION_CREDENTIALS' not in os.environ:
            print("警告: 未設置GOOGLE_APPLICATION_CREDENTIALS環境變量")
            print("請設置環境變量指向您的服務帳號密鑰文件:")
            print("export GOOGLE_APPLICATION_CREDENTIALS=YOUR_CRED_PATH.json")
            raise Exception("未設置GOOGLE_APPLICATION_CREDENTIALS環境變量")
        
        # 初始化 Firebase 應用
        firebase_admin.initialize_app()
        return firestore.client()
    except Exception as e:
        print(f"初始化 Firebase 時出錯: {e}")
        sys.exit(1)

def count_collection(db, collection_name, timeout=120):
    """
    計算 Firestore 集合中的文檔數量
    
    Args:
        db: Firestore client
        collection_name: 集合名稱
        timeout: 超時時間（秒）
    """
    print(f"正在計算 {collection_name} 集合中的文檔數量...")
    start_time = time.time()
    
    collection_ref = db.collection(collection_name)
    
    # 使用快照查詢來計數
    try:
        # 嘗試計算文檔數量（使用更高效的方法）
        docs = collection_ref.limit(1000000).get(timeout=timeout)
        count = len(docs)
        
        elapsed_time = time.time() - start_time
        print(f"✅ {collection_name}: {count} 條記錄 (用時 {elapsed_time:.2f} 秒)")
        return {
            "collection": collection_name,
            "count": count,
            "duration_seconds": round(elapsed_time, 2),
            "status": "success"
        }
    except Exception as e:
        elapsed_time = time.time() - start_time
        print(f"❌ 計算 {collection_name} 時出錯: {e}")
        return {
            "collection": collection_name,
            "count": 0,
            "duration_seconds": round(elapsed_time, 2),
            "status": "error",
            "error": str(e)
        }

def main():
    # 解析命令行參數
    parser = argparse.ArgumentParser(description='計算 Firestore 集合中的文檔數量')
    parser.add_argument('--output', default='firestore_counts', help='輸出文件名（不含擴展名）')
    parser.add_argument('--timeout', type=int, default=120, help='每個集合的超時時間（秒）')
    args = parser.parse_args()
    
    # 輸出文件名
    output_json = f"{args.output}.json"
    output_md = f"{args.output}.md"
    
    # 初始化 Firebase
    db = init_firebase_app()
    
    # 創建結果字典
    results = {
        "timestamp": datetime.now().isoformat(),
        "collections": [],
        "summary": {
            "total_collections": len(COLLECTIONS),
            "total_documents": 0,
            "total_duration_seconds": 0,
            "successful_collections": 0,
            "failed_collections": 0
        }
    }
    
    # 計算每個集合的文檔數量
    for collection_name in COLLECTIONS:
        result = count_collection(db, collection_name, timeout=args.timeout)
        results["collections"].append(result)
        
        # 更新總計
        if result["status"] == "success":
            results["summary"]["total_documents"] += result["count"]
            results["summary"]["successful_collections"] += 1
        else:
            results["summary"]["failed_collections"] += 1
        
        results["summary"]["total_duration_seconds"] += result["duration_seconds"]
    
    # 排序結果 (按記錄數量降序)
    results["collections"] = sorted(results["collections"], key=lambda x: x["count"], reverse=True)
    
    # 輸出結果到文件
    with open(output_json, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)
    
    # 生成 Markdown 報告
    with open(output_md, "w", encoding="utf-8") as f:
        f.write("# Firestore 集合記錄數量統計\n\n")
        f.write(f"統計時間: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")
        
        f.write("## 總結\n\n")
        f.write(f"- 總集合數: {results['summary']['total_collections']}\n")
        f.write(f"- 成功統計的集合: {results['summary']['successful_collections']}\n")
        f.write(f"- 統計失敗的集合: {results['summary']['failed_collections']}\n")
        f.write(f"- 總文檔數: {results['summary']['total_documents']:,}\n")
        f.write(f"- 總處理時間: {results['summary']['total_duration_seconds']:.2f} 秒\n\n")
        
        f.write("## 詳細統計\n\n")
        f.write("| 集合名稱 | 記錄數量 | 處理時間 (秒) | 狀態 |\n")
        f.write("|------------|---------|--------------|--------|\n")
        
        for result in results["collections"]:
            status = "✅ 成功" if result["status"] == "success" else "❌ 失敗"
            f.write(f"| {result['collection']} | {result['count']:,} | {result['duration_seconds']} | {status} |\n")
    
    # 打印總結到控制台
    print("\n==============================================")
    print("                  統計結果                   ")
    print("==============================================")
    print(f"總集合數: {results['summary']['total_collections']}")
    print(f"成功統計的集合: {results['summary']['successful_collections']}")
    print(f"統計失敗的集合: {results['summary']['failed_collections']}")
    print(f"總文檔數: {results['summary']['total_documents']:,}")
    print(f"總處理時間: {results['summary']['total_duration_seconds']:.2f} 秒")
    print("==============================================")
    print(f"詳細結果已保存到 {output_json} 和 {output_md}")

if __name__ == "__main__":
    main()