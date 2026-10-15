# 已应用 SQL 留档

这些文件来自现有项目的本地开发留档，保留业务表、权限、账号和订单流程的实现，供协作者阅读。
它们不是幂等脚本，**不要在现有生产数据库重新运行**。

历史顺序：

1. `applied-initialization.sql`：最初的业务表、RLS 和照片存储规则。
2. `address-simplification.sql`：地址保存后可下单，取消人工地址审核。
3. `next-day-delivery.sql`：按取货日推算次日配送。
4. `admin-list-users.sql`：私有 schema 和管理员用户查询。
5. `managed-accounts.sql`：管理员分配自定义账号，阻止公开注册。
6. `fix-managed-account-timing.sql`：在 Auth 事务结束时校验最终账号资料并建档。
7. `workflow-migration.sql`：每日流水号、品名预设、司机取货及中国仓库收货。
8. `simplify-order-migration.sql`：双方无邮编、无英文品名等最新下单字段规则。

这是历史源码留档，未声明为从零可复现的完整 Supabase migration 集合。
历史上另有内部触发器执行权限调整等操作；部署到新项目时必须与线上结构和迁移记录核对，先在测试项目完成验证。
最初的验证函数会被后续文件更新；旧版脚本出现照片、邮编或英文品名要求，不代表当前界面仍要求填写。

9. `role-permissions.sql`：六种角色、系统管理员权限管理、工作人员订单隔离及订单修改留档。包含随后增加的下单工作人员字段重置保护。

10. `package-workflow.sql`：仓库合并包裹、手提员分配、司机私有取货照片与管理员可恢复删除。

11. `pickup-date-numbering.sql`：以中国取货日期分配订单流水号，管理员修改取货日期时记录旧号并重新编号。
