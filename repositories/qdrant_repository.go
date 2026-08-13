package repositories

import (
	"context"
	"crypto/md5"
	"fmt"
	"time"

	"assistant/config"

	"github.com/qdrant/go-client/qdrant"
)

type QdrantRepository struct {
	client *qdrant.Client
}

func NewQdrantRepository() (*QdrantRepository, error) {
	host := config.GlobalConfig.QdrantHost
	port := 6334
	fmt.Printf("Connecting to Qdrant at %s:%d\n", host, port)

	client, err := qdrant.NewClient(&qdrant.Config{
		Host: host,
		Port: port,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to connect to qdrant: %w", err)
	}

	return &QdrantRepository{client: client}, nil
}

// GenerateUUIDFromID 利用确定性 MD5 哈希将非标准主键格式 (如 mem_xxx) 幂等映射为严格符合 RFC 4122 规范的 UUID 格式
func GenerateUUIDFromID(id string) string {
	hasher := md5.New()
	hasher.Write([]byte(id))
	hash := hasher.Sum(nil)
	
	// 转换字节以符合 UUID 变体及版本规范 (Version 4 伪随机哈希标准)
	hash[8] = (hash[8] & 0x3f) | 0x80
	hash[6] = (hash[6] & 0x0f) | 0x40
	
	return fmt.Sprintf("%x-%x-%x-%x-%x", hash[0:4], hash[4:6], hash[6:8], hash[8:10], hash[10:16])
}

func (r *QdrantRepository) Close() error {
	if r.client != nil {
		return r.client.Close()
	}
	return nil
}

// InitCollection 动态创建指定大小与余弦度量的 Collection
func (r *QdrantRepository) InitCollection(ctx context.Context, name string, vectorSize uint64) error {
	exists, err := r.CollectionExists(ctx, name)
	if err != nil {
		return fmt.Errorf("failed to check if collection exists: %w", err)
	}
	if exists {
		return nil
	}

	err = r.client.CreateCollection(ctx, &qdrant.CreateCollection{
		CollectionName: name,
		VectorsConfig: qdrant.NewVectorsConfig(&qdrant.VectorParams{
			Size:     vectorSize,
			Distance: qdrant.Distance_Cosine,
		}),
	})
	if err != nil {
		return fmt.Errorf("failed to create collection: %w", err)
	}

	// 为高频字段创建 Payload Index 索引以优化性能
	payloadFields := []struct {
		name      string
		fieldType qdrant.FieldType
	}{
		{"memory_id", qdrant.FieldType_FieldTypeKeyword},
		{"tags", qdrant.FieldType_FieldTypeKeyword},
		{"extracted_time", qdrant.FieldType_FieldTypeKeyword},
		{"priority", qdrant.FieldType_FieldTypeInteger},
		{"created_at", qdrant.FieldType_FieldTypeInteger},
	}

	for _, field := range payloadFields {
		_, err = r.client.CreateFieldIndex(ctx, &qdrant.CreateFieldIndexCollection{
			CollectionName: name,
			FieldName:      field.name,
			FieldType:      field.fieldType.Enum(),
		})
		if err != nil {
			fmt.Printf("Warning: failed to create payload index on field %s: %v\n", field.name, err)
		}
	}

	return nil
}

// SaveVector 存储向量和对应的 Payload
func (r *QdrantRepository) SaveVector(ctx context.Context, collection string, id string, vector []float32, payload map[string]interface{}) error {
	// 转换 payload 中不支持的类型（如 []string -> []interface{}）以兼容 Qdrant go-client 的 NewValueMap
	cleanedPayload := make(map[string]interface{})
	for k, v := range payload {
		if strSlice, ok := v.([]string); ok {
			interfaceSlice := make([]interface{}, len(strSlice))
			for i, s := range strSlice {
				interfaceSlice[i] = s
			}
			cleanedPayload[k] = interfaceSlice
		} else {
			cleanedPayload[k] = v
		}
	}

	points := []*qdrant.PointStruct{
		{
			Id:      qdrant.NewIDUUID(GenerateUUIDFromID(id)),
			Vectors: qdrant.NewVectors(vector...),
			Payload: qdrant.NewValueMap(cleanedPayload),
		},
	}

	_, err := r.client.Upsert(ctx, &qdrant.UpsertPoints{
		CollectionName: collection,
		Points:          points,
	})
	if err != nil {
		return fmt.Errorf("failed to upsert point: %w", err)
	}

	return nil
}

// DeleteVector 物理删除向量
func (r *QdrantRepository) DeleteVector(ctx context.Context, collection string, id string) error {
	_, err := r.client.Delete(ctx, &qdrant.DeletePoints{
		CollectionName: collection,
		Points: &qdrant.PointsSelector{
			PointsSelectorOneOf: &qdrant.PointsSelector_Points{
				Points: &qdrant.PointsIdsList{
					Ids: []*qdrant.PointId{
						{
							PointIdOptions: &qdrant.PointId_Uuid{
								Uuid: GenerateUUIDFromID(id),
							},
						},
					},
				},
			},
		},
	})
	if err != nil {
		return fmt.Errorf("failed to delete vector point: %w", err)
	}
	return nil
}

type SearchResult struct {
	MemoryID string
	Score    float32
	Payload  map[string]interface{}
}

// SearchSimilar 执行向量语义检索
func (r *QdrantRepository) SearchSimilar(ctx context.Context, collection string, vector []float32, limit uint64) ([]SearchResult, error) {
	res, err := r.client.Query(ctx, &qdrant.QueryPoints{
		CollectionName: collection,
		Query:          qdrant.NewQuery(vector...),
		Limit:          &limit,
		WithPayload:    qdrant.NewWithPayload(true),
	})
	if err != nil {
		return nil, fmt.Errorf("failed to query points: %w", err)
	}

	var results []SearchResult
	for _, point := range res {
		memoryIDVal := point.Payload["memory_id"]
		var memoryID string
		if memoryIDVal != nil {
			memoryID = memoryIDVal.GetStringValue()
		} else {
			memoryID = point.Id.GetUuid()
		}

		payloadMap := make(map[string]interface{})
		for k, v := range point.Payload {
			payloadMap[k] = unpackValue(v)
		}

		results = append(results, SearchResult{
			MemoryID: memoryID,
			Score:    point.Score,
			Payload:  payloadMap,
		})
	}

	return results, nil
}

// GetCollectionCount 获取 Qdrant 集合内的向量点总数，供仪表盘使用
func (r *QdrantRepository) GetCollectionCount(ctx context.Context, collection string) (uint64, error) {
	exists, err := r.CollectionExists(ctx, collection)
	if err != nil || !exists {
		return 0, nil
	}

	info, err := r.client.GetCollectionInfo(ctx, collection)
	if err != nil {
		return 0, fmt.Errorf("failed to get collection info: %w", err)
	}

	if info.PointsCount == nil {
		return 0, nil
	}
	return *info.PointsCount, nil
}

// CollectionExists 检查集合是否存在
func (r *QdrantRepository) CollectionExists(ctx context.Context, collection string) (bool, error) {
	collections, err := r.ListCollections(ctx)
	if err != nil {
		return false, err
	}
	for _, col := range collections {
		if col == collection {
			return true, nil
		}
	}
	return false, nil
}

// HasCollection 兼容外部调用的 HasCollection
func (r *QdrantRepository) HasCollection(ctx context.Context, collection string) (bool, error) {
	return r.CollectionExists(ctx, collection)
}

// ListCollections 列出所有的 Collections
func (r *QdrantRepository) ListCollections(ctx context.Context) ([]string, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	
	res, err := r.client.ListCollections(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to list collections: %w", err)
	}
	return res, nil
}

// unpackValue 将 *qdrant.Value 反序列化为 Go 的原生 interface{}，支持复杂数据解包
func unpackValue(val *qdrant.Value) interface{} {
	if val == nil {
		return nil
	}
	switch v := val.Kind.(type) {
	case *qdrant.Value_NullValue:
		return nil
	case *qdrant.Value_BoolValue:
		return v.BoolValue
	case *qdrant.Value_IntegerValue:
		return v.IntegerValue
	case *qdrant.Value_DoubleValue:
		return v.DoubleValue
	case *qdrant.Value_StringValue:
		return v.StringValue
	case *qdrant.Value_ListValue:
		var list []interface{}
		for _, item := range v.ListValue.Values {
			list = append(list, unpackValue(item))
		}
		return list
	case *qdrant.Value_StructValue:
		m := make(map[string]interface{})
		for k, item := range v.StructValue.Fields {
			m[k] = unpackValue(item)
		}
		return m
	}
	return nil
}
