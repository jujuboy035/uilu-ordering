# 协作修改

1. 由仓库所有者在 GitHub 的 Settings → Collaborators 中邀请朋友，使用各自账号。
2. 开始修改前拉取最新 main；每次修改创建独立分支，例如 `fix/order-form`。
3. 修改 `frontend/index.html`、后台函数或相关 SQL 源码；运行 `npm test`。
4. 提交并推送分支，在 GitHub 创建 Pull Request，写清修改内容和验证结果。
5. 对方核对后合并；完成正式发布后记录部署版本。

网站源码、Supabase 控制台及正式网站发布权限分别管理。GitHub 协作者不会自动获得 Supabase 权限。

不要提交 `.env`、服务端密钥、真实密码、数据库备份或客户订单资料。新增 SQL 需说明适用版本和验证方式；不要在现有生产项目重复运行历史初始化脚本。
