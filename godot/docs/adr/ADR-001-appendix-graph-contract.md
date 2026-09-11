# /heartloom/graph API 契约(ADR-001 附录)

状态:契约冻结(2026-09-12),前端可依此 mock 并行开发;后端在 ADR-001 Phase 3 实现。
鉴权:与其他端点一致,X-API-Key 头(GET 握手/请求)。

## 请求

```
GET /heartloom/graph?save_id=<journey>&role_id=ling&limit=120&cursor=<opaque>
```

| 参数 | 类型 | 说明 |
|------|------|------|
| save_id | 必填 | 旅程键(即 journey) |
| role_id | 可选 | 过滤 scope_role_id = 该角色或 '*' |
| limit | 可选 | 节点上限,默认 120,最大 300(硬上限) |
| cursor | 可选 | 上一响应返回的游标(opaque,服务端校验) |

## 响应

```json
{
  "status": "ok",
  "data": {
    "graph_version": 2,
    "nodes": [
      {
        "memory_id": "mem-...",
        "kind": "episodic",
        "title": "一起浇了窗边的栀子花",
        "summary": "内容前 120 字……",
        "lifecycle": "active",
        "is_second_hand": false,
        "importance_bucket": "high",
        "world_created_at": 123.5,
        "world_updated_at": 130.2
      }
    ],
    "edges": [
      {
        "link_id": "link-...",
        "src": "mem-new",
        "dst": "mem-old",
        "link_type": "association",
        "link_strength": 0.72,
        "reason": "词条命中:栀子花"
      }
    ],
    "cursor": "op-aque",
    "truncated": true,
    "node_count": 120
  }
}
```

## 契约规则

1. **默认仅返回 lifecycle='active'**;dormant/archived 只有显式 `include_lifecycle` 查询参数(Phase 2)才返回。
2. `edges` 只包含 `nodes` 集合内部的边(无悬空引用);`src`/`dst` 语义为存储方向(src=new → dst=old),**前端按无向边渲染**。
3. `truncated=true` 时附带 `cursor`,客户端用它请求下一页;`node_count` 为本页节点数。
4. 节点上限 300(服务端硬限);客户端建议 >150 节点时启用聚类/分组渲染。
5. `importance_bucket` 为定性三档(high/normal/low,由 importance 分桶派生)——**契约层不输出原始浮点分数**(呼应 #29 出域约束;link_strength 供前端布局用,属图结构元数据,非生理状态)。
6. 错误:401(鉴权)、400(参数/未知 save_id)、503(Core 内部存储不可用)。

## 前端 mock

`godot/mock/heartloom_graph_sample.json`(本契约样例数据),开发期直接加载渲染力导向图;节点 >150 时降级为聚类/分组渲染(ADR-001 负面后果条目)。
