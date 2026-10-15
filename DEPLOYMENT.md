# 环境与发布

## 当前环境

- 网站：https://kuilu-ordering.wavypond9.chatgpt.site/
- Supabase 项目：`swzlnzjkcxsctablyeaa`
- 网站托管：Sites 静态网页；当前交付入口为 `frontend/index.html`。
- 后端：Supabase Auth、Postgres、私有 Storage、Edge Functions。

## 前端发布

1. 在修改分支完成检查并合并 main。
2. 使用现有 Sites 项目的发布流程，将当前 `frontend/index.html` 作为静态目录中的 `index.html` 打包。
3. 发布后核对登录页、中日切换和下单表单；需要真实提交时使用专用测试账号。

GitHub 不会自动将代码同步到现有线上网站。本仓库没有自动发布凭证或 GitHub Actions 部署任务。
代码变更、SQL 执行和 Edge Function 部署分别进行。

## 账号管理 Edge Function

函数名：`kuilu-manage-accounts`。源码使用固定版本 `npm:@supabase/supabase-js@2.117.3`。

服务端运行环境需提供 `SUPABASE_URL` 和 `SUPABASE_SERVICE_ROLE_KEY`；代码通过 `Deno.env.get` 读取，不把值写进源码。
现有部署关闭平台的 JWT 预校验（`verify_jwt=false`），函数自身始终通过 `auth.getUser` 验证 Bearer 凭证，并查询数据库确认管理员角色。不得移除这两层检查。

允许的网页来源在 `allowedOrigins` 中列出。换域名或添加测试环境时，需核对前端地址、函数来源白名单以及 Auth 回跳设置。
在本地预览中临时添加来源也需要重新部署函数；建议为开发建立独立 Supabase 测试项目。

## 数据库

现有生产项目已经配置完成。`supabase/sql-history/` 是执行过的业务 SQL 留档，不是可反复执行的安装脚本。
新环境需要先整理并验证完整迁移，以及单独初始化第一位管理员；本仓库没有自动导入生产用户或客户数据。

数据库回归脚本放在 `tests/sql/`，使用事务、模拟身份和回滚。执行前阅读脚本，核对目标项目和当前结构，优先使用测试环境。
