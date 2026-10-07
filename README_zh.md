# BEM 任务悬赏板（BountyBoard）

## 一、概念
**使用场景**：BEM 社区里有大量小任务——翻译、设计海报、写推文/教程、测试 bug、做短视频等。发布者用 BEM 悬赏，任何人都可以接单提交成果，发布者验收后合约自动付款。

**需求**：社区小额协作缺少可信的托管方——发布者担心付了钱没成果，干活的人担心交了成果拿不到钱。本合约把赏金锁在链上，规则公开、无管理员。

**用户如何赚 BEM**：浏览任务 → 完成并提交成果链接 → 发布者批准，或发布者 3 天内未处理时自行“超时领取” → 收到奖励的 90%。

**销毁机制**（常量，不可修改）：
- 发布任务：实际到账金额的 **0.5%** 立即转入 `0x...dEaD` 销毁；
- 支付奖励：奖励的 **10%**（`BURN_BPS = 1000`）销毁，90% 给工作者；
- 取消/取回：全额退还托管奖励，不再额外销毁；
- 每次销毁都会触发 `Burned` 事件，`totalBurned` 记录累计销毁量，前端会显示出来。

## 二、合约规则
| 操作 | 谁 | 条件 |
|---|---|---|
| `createTask(amount, deadline, uri)` | 任何人 | 需先 approve；截止时间至少 1 小时后；按实际到账计算（兼容转账收费代币） |
| `submit(id, uri)` | 非发布者 | 任务状态为“进行中”且未过截止时间；先提交者锁定任务 |
| `approve(id)` | 发布者 | 有待审核提交 → 支付 90%，销毁 10% |
| `reject(id)` | 发布者 | 提交后 3 天内可拒绝，任务恢复为“进行中” |
| `claim(id)` | 提交者 | 提交超过 3 天发布者仍未处理 → 自动批准 |
| `cancel(id)` | 发布者 | 没有待审核提交 → 全额退款 |
| `reclaim(id)` | 发布者 | 已过截止时间且没有待审核提交 → 取回 |

安全措施：ReentrancyGuard、SafeERC20、先改状态再转账（CEI）、不可升级、无 owner、没有任何提取用户资金的函数。代币精度由构造函数读取 `decimals()`。

## 三、测试
```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
git init && forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 foundry-rs/forge-std   # 压缩包不含 lib/
forge test -vv
```
静态分析结果见 `slither_report.txt`（9 条提示：createTask 中 transferFrom 后写状态——为测量实际到账所必需，且有 nonReentrant 保护；时间戳比较；严格相等判断，均已评估为可接受）。

覆盖：正常流程、销毁金额、取消、超时领取、截止取回、拒绝后重新提交、权限、参数校验、重复批准、转账收费代币、恶意代币重入、模糊测试资金守恒。

## 四、部署
```bash
export PRIVATE_KEY=0x你的私钥   # 建议使用专用部署钱包，切勿提交到 git
# 1) 测试网（chainId 97）：会自动部署 MockBEM 并给部署者铸造 1000 万枚
forge script script/Deploy.s.sol --rpc-url bsc_testnet --broadcast
# 复用已有 MockBEM 只重新部署 BountyBoard： MOCK_BEM=0x... forge script ...（同上）
# 2) 测试网完整走一遍流程后，再部署主网（chainId 56）：使用真实 BEM 0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a
forge script script/Deploy.s.sol --rpc-url bsc --broadcast
# 可选：在 BscScan 验证源码 —— 加 --verify --etherscan-api-key <KEY>
```
测试网 BNB 可从 https://www.bnbchain.org/en/testnet-faucet 领取。

### 前端
修改 `frontend/config.js` 中的 `chainId / rpcUrl / boardAddress`，然后：
```bash
cd frontend && python3 -m http.server 8080   # 打开 http://localhost:8080
```
也可以直接部署到任意静态托管（GitHub Pages、Vercel、IPFS）。

## 五、在 TapeHub 上登记为生态项目
1. 打开 https://tapehub.ai/projects/new ，用**你自己的钱包**连接（本项目不会代你操作）；
2. 填写：项目名称（BEM 任务悬赏板）、简介（可直接复制本文“概念”一节）、合约地址（主网 BountyBoard 地址及 BscScan 链接）、前端网址、代码仓库；
3. 按页面提示签名/提交。具体字段以页面实际为准。

## 六、风险提示
- **合约未经审计**，仅通过本地单元测试与静态分析，请小额使用，风险自担。
- BEM 代币与 TapeHub 均**未找到官方技术文档**；BEM 精度据称为 8 位（合约运行时读取），若 BEM 有转账税、黑名单、暂停等特殊逻辑，可能影响托管或销毁。上线主网前请先用小额实际测试。
- 争议机制很简单：发布者可以在审核窗口内反复拒绝合格的成果（链上无法判断质量），工作者只能防“不处理”而无法防“恶意拒绝”。请选择信誉良好的发布者。
- 任务描述和提交内容为公开链接，请勿放敏感信息。
- 私钥只放在环境变量里，切勿泄露或提交到仓库。

## 七、测试网部署记录（BSC Testnet, chainId 97）
- MockBEM：`0xAf81078FA7DF6aF5E5bD97B98a358939600EC320`
- BountyBoard（BURN_BPS=1000）：`0xA6C5C0Eca8294aA27DB93EbB5c37Df744FF0BD08`
- 旧版 BountyBoard（BURN_BPS=200，已弃用）：`0x5c53b5d06f93268dE480735403e7349924E00EB3`

## 许可证
MIT，见 LICENSE。

## 主网部署（BSC，chainId 56）

- BountyBoard：[`0xaf81078fa7df6af5e5bd97b98a358939600ec320`](https://bscscan.com/address/0xaf81078fa7df6af5e5bd97b98a358939600ec320)
- 绑定代币 BEM：`0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a`（8 位小数）
- 部署交易：[`0x7b8ac211…3e2c`](https://bscscan.com/tx/0x7b8ac2111edf160536fa1654d6e91863723607b941e2c8c2253350e477f73e2c)
- 销毁：发布 0.5%，支付 10%，均转入 `0x…dEaD`
- 合约未经审计，请先小额使用。
