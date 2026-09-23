# 事件 → 副作用對照表

「收到某個事件時，要推什麼、要寫什麼」的唯一規格。改 `AppModel` 之前先看這張表。
（LA = 即時動態；「重要」= `LiveActivityManager.Priority.important`，背景被系統擋住時仍會嘗試。）

| 事件 | session | LA 推送 | 小工具 | tick |
|---|---|---|---|---|
| 換歌 `.newTrack` | playing / paused | 重要（歌詞載入後再一次） | `publish(debounce:)` | 重新排程 |
| 「沒在播放」後同一首回來 `.resumeTrack`（30 分鐘內） | playing / paused | 重要 | `publish()` 立即 | 重新排程；歌詞沿用不重載 |
| 拖動 `.seeked` | 不變 | 重要 | `publish()` 立即 | 重新排程 |
| 播放 / 暫停 `.playStateChanged` | playing / paused | 重要 | `publish(debounce:)` | 重新排程 |
| 進度微調 `.none` / 過期 `.stale` | 不變 | 無 | `refreshFile()`（只寫檔，不佔額度） | 無 |
| 換句（tick 內） | 不變 | routine | `lineChanged()`（由 `WidgetReloadPolicy` 決定） | 由 tick 自行排程 |
| 歌詞狀態改變 | 不變 | 重要 | `publish(debounce:)`（先於 tick） | 重新排程 |
| 封面下載完成 | 不變 | 重要 | `publish(debounce:)` | 無 |
| 調整延遲 | 不變 | 由 tick 帶動 | `publish()` 立即 | 重新排程 |
| 廣告 / Podcast 開始 | nonMusic | 重要（僅狀態改變時） | `publish(.idle)`（僅狀態改變時） | 無 |
| 廣告結束回到音樂 | playing / paused（**先於** `applyPlayback`） | 重要（`force`） | 依 change | 依 change |
| 沒有播放（連兩次 204） | notPlaying（僅第一次） | 重要（僅第一次） | `publish(.idle)`（僅第一次） | 無（歌詞留著、記住這首；車上前 2 分鐘每 5 秒再問） |
| 播放控制成功（樂觀更新） | playing / paused | 重要 | `publish()` 立即 | 重新排程 |
| 回到前景 | 不變 | 佔位（重要）+ `flush()`；閒置計時重新起算 | 由後續事件帶動 | 由後續事件帶動 |
| 連上車用音訊（真的連上） | 不變 | 「開車時」模式：佔位（重要）；閒置計時重新起算；背景時 8 秒後仍沒有即時動態 → 本機通知 | 無 | 無 |
| 車用音訊離開 | 不變 | 先等 30 秒寬限（閃斷常見）；到期才 `end()`、結束開車模式與定位保活 | 無 | 無 |
| 進入背景（背景執行關閉） | 不變 | `end()` | `publish(.idle)` | 停止 |
| 閒置逾時 | 不變 | `end()` | `publish(.idle)` | 停止 |
| 登出 | loggedOut | `end()` | `publish(.idle)` | 停止 |

閒置門檻（`IdlePolicy`，連著車用音訊時 ×3）：沒有播放 10 分鐘、暫停 30 分鐘、廣告／Podcast 播放中 60 分鐘。前景永遠不停。
閒置計時在上車、即時動態開始、回到前景、閒置停止後重新輪詢時重新起算（`PlaybackState.restartIdleClock`）。

另一條較短的門檻只收起即時動態、不停止背景執行（設定：「沒在播放時收起即時動態」，預設開）：
Spotify 沒在播放 30 秒、暫停 5 分鐘 → `endActivity`，動態島就不會一直被佔用；連著車用音訊時暫停不收、沒在播放 30 分鐘才收；音訊中斷中（電話）不算閒置；
廣告／Podcast 播放中不收起。恢復播放時 App 會重新開一個（背景開不起來的話，要再打開一次 App）。

定位保活（設定「鎖定時也更新歌詞（使用定位）」，預設關）：`updateIdleTimer` 每次都會重新評估 `LocationKeepAlivePolicy`——
設定開、已登入、即時動態有開且進行中、在車上（或按過「現在顯示」）時在前景開始；下車、即時動態結束、登出、關設定就停；
沒問過權限時在前景詢問一次。送出即時動態時的執行理由（前景／音訊／背景任務／定位）記在 `LiveActivityManager.reasons`。
