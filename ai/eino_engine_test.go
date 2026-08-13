package ai

import (
	"reflect"
	"testing"
)

func TestExecuteRRF(t *testing.T) {
	// 单元测试环境不需要完整的数据库连接，只测试 RRF 重排逻辑的准确性
	engine := &EinoEngine{}

	sqlIDs := []string{"mem_1", "mem_2", "mem_3"}
	vecIDs := []string{"mem_3", "mem_4", "mem_1"}

	// 复制原始输入，用于断后验证防数据篡改
	sqlIDsBackup := make([]string, len(sqlIDs))
	copy(sqlIDsBackup, sqlIDs)
	vecIDsBackup := make([]string, len(vecIDs))
	copy(vecIDsBackup, vecIDs)

	results := engine.ExecuteRRF(sqlIDs, vecIDs)

	// 1. 验证输入切片没有被修改
	if !reflect.DeepEqual(sqlIDs, sqlIDsBackup) {
		t.Errorf("ExecuteRRF mutated input sqlIDs slice: got %v, expected %v", sqlIDs, sqlIDsBackup)
	}
	if !reflect.DeepEqual(vecIDs, vecIDsBackup) {
		t.Errorf("ExecuteRRF mutated input vecIDs slice: got %v, expected %v", vecIDs, vecIDsBackup)
	}

	// 2. 计算预期得分：
	// wSQL = 1.5, wVec = 1.0, k = 60
	// mem_1 在 SQL 排名 0, Vector 排名 2
	// Score(mem_1) = 1.5 * (1 / (60 + 0)) + 1.0 * (1 / (60 + 2)) = 1.5/60 + 1.0/62 ≈ 0.025 + 0.0161 = 0.0411
	//
	// mem_2 在 SQL 排名 1, Vector 未召回
	// Score(mem_2) = 1.5 * (1 / (60 + 1)) + 0 = 1.5/61 ≈ 0.0245
	//
	// mem_3 在 SQL 排名 2, Vector 排名 0
	// Score(mem_3) = 1.5 * (1 / (60 + 2)) + 1.0 * (1 / (60 + 0)) = 1.5/62 + 1.0/60 ≈ 0.0241 + 0.0166 = 0.0408
	//
	// mem_4 在 SQL 未召回, Vector 排名 1
	// Score(mem_4) = 0 + 1.0 * (1 / (60 + 1)) = 1.0/61 ≈ 0.0163
	//
	// 所以综合得分排序应该是: mem_1 > mem_3 > mem_2 > mem_4

	expectedOrder := []string{"mem_1", "mem_3", "mem_2", "mem_4"}
	if !reflect.DeepEqual(results, expectedOrder) {
		t.Errorf("ExecuteRRF order mismatch: got %v, expected %v", results, expectedOrder)
	}

	t.Logf("ExecuteRRF passed successfully. Results: %v", results)
}

func TestExecuteRRFLimit(t *testing.T) {
	engine := &EinoEngine{}

	// 测试超过 5 个结果时的 Top-5 截断机制
	sqlIDs := []string{"id_1", "id_2", "id_3", "id_4", "id_5", "id_6", "id_7"}
	vecIDs := []string{"id_7", "id_6", "id_5", "id_4", "id_3", "id_2", "id_1"}

	results := engine.ExecuteRRF(sqlIDs, vecIDs)

	if len(results) != 5 {
		t.Errorf("ExecuteRRF did not limit top 5: got size %d, expected 5", len(results))
	}
}
