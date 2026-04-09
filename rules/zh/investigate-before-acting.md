# 先调查再行动

> 来源：提炼自 `~/.claude/notes/` Behavioral Rules 中的这些原则：Investigate before reversing、Never rollback without asking、Wrong root cause attribution、Read source before analyzing、Scope full problem before solutions、Search before asserting nonexistence、Verify symlinks、Verify subagent claims、Don't modify unrelated infrastructure、Web search before asking。

## 规则

在修复、回滚或下任何结论之前，**先调查**。读实际代码。复现问题。画出完整影响范围。暂停几分钟理解问题，成本很低；基于错误假设行动，往往会带来数小时的清理成本。

## 调查顺序

1. **阅读**：阅读涉及的完整源文件，而不是只看 grep 片段。在提出修改前先弄清楚实际已有内容。
2. **复现**：确认问题确实如描述那样存在。也要检查是否是自己刚刚引入的问题。
3. **定界**：在提出方案前，梳理所有受影响组件。理解不完整，只会带来制造新问题的不完整修复。
4. **搜索**：在断言某个东西不存在之前，先去找。训练数据里没见过，不代表它不存在。遇到陌生术语时，先搜网页，再问用户；本地 grep 不够。
5. **诊断**：找出根因。先检查是不是代理自己之前的操作导致了问题，而不是先怪外部系统。
6. **然后再行动**：只有完成 1-5 后，才开始修改。

## 反模式

| 陷阱 | 修正方式 |
|------|----------|
| 为了“修复”问题直接回滚代码 | 先诊断，再修复；回滚只能作为最后手段，而且必须得到用户批准 |
| 根据表面症状猜根因 | 阅读真实报错，跟踪真实代码路径 |
| 问题在文件 B，却对文件 A 提方案 | 先完整梳理所有相关组件 |
| 基于训练记忆断言“这不存在” | 先搜索文件系统、网页或包注册表 |
| 问题复发就先怪 hooks/agents/CI | 先检查是不是自己之前的动作造成的 |
| 直接相信子代理给出的删除分类 | 每一项都独立核实，子代理会误判自定义文件 |
| 只靠本地文件猜陌生术语含义 | 先搜网页，其次再本地 grep，最后才问用户 |
