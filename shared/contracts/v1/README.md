# P0-08 跨端契约 v1.0.0

JSON Schema draft2020-12；唯一规范文件contract.schema.json。按kind选择实体；UTF8 JSON、snake_case字段、UUID逻辑身份、SHA256小写hex。文件无Key、真实聊天或可用模型目录。examples仅合成形状示例；全0哈希是占位，不是实际文件校验结果，100/20等示例计数不构成A03算法证据。

覆盖Workspace/Group/ImportEvent/Batch/MessageOccurrence/CanonicalMessage/DedupDecision/Collection/Template/ModelProfile/Generation/Brief和接收ready、事件、分项错误、模型目录。契约独立于两端内部SQLite布局；API Key禁止出现在任何契约字段，只有credential_ref。新增向后不兼容字段/语义必须升主版本，不得静默更改既有快照。

## Schema之外必须执行的语义

- 所有外键在同工作空间内解析；dedup只允许同group_id，occurrence全部保留，撤销引用旧决定，不改原件。发送人/分钟时间/正文相同不足确认，批内复读次数保留。
- counts.imported = confirmed_duplicate + new + unparsed，suspected <= new。疑似是新增子集。
- source_locator由batch UUID、百分号编码的entry和1-based ordinal组成；必须回查真实occurrence，不能信任任意字符串。source_entry保留原名。时间原文不改；unknown不填推断时间，已解释时间须同时带IANA时区。用户本地展示时区不冒充源时区。
- relative_path必须在Inbox/归档根内；两端用规范路径验证、拒绝符号链接/绝对路径/父路径/设备名，Schema路径正则只是一层筛选。名字使用App生成UUID，原名仅metadata；大小非负、逐文件哈希回算、附件全部成功持久写后原子ready。同批UUID消费幂等；partial永不作为ready。
- event.failed必须有error；非failed不可夹带错误。日志只记录stage/code/UUID/计数，不记聊天/Key或供应商原始错误响应；message_key是本地化键，不接受任意堆栈。超时/429有限重试，auth失败不无限重试。
- model.available仅当mac_verified与windows_verified都为true，且该catalog_version有真实调用证据；目录未核实前不填实际服务地址/型号。endpoint只能来自受控目录，不接受聊天或用户模板覆盖。预算/参数不成为用户必填项。
- snapshot冻结消息、批次、模板/服务商/目录版本和包含起止日的解释时区；snapshot_hash按下文稳定字节约定计算，不拿平台默认JSON输出直接散列。
- generation.covered_message_ids必须在快照内，引用occurrence属于选中消息；每个选中ID至少覆盖一段，有失败段不可标draft/saved。saved还必须有对应Brief成功写入/回读证据，不能由模型返回成功决定。
- brief.saved必须有saved_path/content_hash/saved_at，回读磁盘一致；草稿不冒充保存。路径必须用户选择和授权，不跟随模型文本写文件。

Schema表达结构，语义由两端实现和共享对照夹具验证；此P0验证不表示P1/P3/P4/P5实现已存在。

验证：`python3 scripts/verify-contracts.py`；需要开发验证依赖jsonschema，当前环境已具备。该依赖只用于设计契约检查，不是产品运行时依赖。双端之后逐项复用这些约束，完整攻击/解析去重夹具在P3-01制作。

## 快照哈希稳定字节约定

取snapshot对象，删除snapshot_hash字段；字段名均为ASCII，按字段名ASCII升序排列。输出UTF8 JSON，无BOM、空白或末尾换行；数组维持选择时固定顺序，不擅自排序；true/false小写，字符串保留原Unicode（不做NFC/换行规范化），引号/反斜线转义，斜线不转义，控制字符使用\b/\t/\n/\f/\r，其余U+0000–001F用小写十六进制\u00xx，其他Unicode直接UTF8。禁止非配对surrogate；本对象不允许浮点/NaN。对字节SHA256得小写hex。任何字段变化都产生新快照，不修改既有snapshot。messages由不可变occurrence及其批次原件哈希回查；变更解析版本需生成新的消息身份/快照，不覆盖旧消息。

golden-snapshot.json提供输入与期望哈希；合成Unicode模板和固定数组顺序用于双端后续实现对照。Python仅为本轮规范验证工具，不能代替两端实际代码对照。

P0-08的“已通过”仅表示Schema、合成结构/示例计数及Python快照回归；未证明跨端业务语义或稳定字节一致。P3-11由Swift/C#各自输出语义/错误结果；P5-01各自输出同一合成输入的稳定字节与哈希，对照冻结向量并覆盖非法输入。不得只比较两个程序均返回成功，也不得将同一Python工具生成和回验视为独立跨端证据。此说明不修改v1 Schema或快照算法。
