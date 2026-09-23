# 試過但沒用的做法

## 背景定位讓即時動態在背景持續更新（2026-09，已移除）

- 想法：iOS 會擋掉「只播放背景音訊」的 App 在背景更新即時動態；加上 `CLLocationManager` 背景定位（最低精準度 + `CLBackgroundActivitySession`），也許系統就不會把 App 當成單純的音訊 App。
- 做法：`LocationKeeper`（`kCLLocationAccuracyThreeKilometers`、`allowsBackgroundLocationUpdates`），Info.plist 加 `location` 背景模式與兩段定位權限說明。
- 結果：實測 debug.log 顯示定位啟動後，鎖定期間的即時動態更新仍然「沒有被系統套用」。沒效又多一個定位權限，整組移除。
- 復原：參考 commit `68ac5f2`（CI #13）。
- 注意：上面「背景更新被擋」的結論是在 CI #31 修正即時動態驗證的競態（送出後太快讀回 `activity.content`，把還沒套用的更新誤判成被拒絕）**之前**量到的，當時的「沒有被系統套用」可能有一部分是驗證本身的誤判。這個結論要用修正後的版本（診斷頁的接受／拒絕次數）重新實測才算數；重新量之前不要拿它當依據。
- 實測結果（驗證修正後，build 36，iOS 26.6.1，iPhone 15 Pro，接著 CarPlay、充電中）：**確認被擋**。進背景 3–13 秒後開始「沒有被系統套用」，連續 8 次後進入「背景被擋」，77 秒後即時動態變成 stale；回到前景立刻恢復（「恢復正常」）。App 內同步完全正確（最晚 0.2 秒）。Apple 文件（Displaying live data with Live Activities）說背景可以 update / end，但實際上只靠背景音訊活著的 App 更新會被丟掉。
- 結論與做法（build 39）：$0 沒有背景更新的替代路徑（推播要伺服器與付費帳號），所以改成「開車模式」：接著 CarPlay 時讓 CarLyrics 留在前景（螢幕不自動關閉、可調暗），並把每次更新的 staleDate 設在「下一句開始 + 2 秒」——被擋時畫面到時自己把下一句升成目前句一次，播完改顯示「打開 CarLyrics」；CarPlay 小工具頁是鎖定後的備援（時間軸驅動，不受這個限制）。

- 第七輪查證（2026-09-23，Apple 開發者論壇）：這不是頻率問題，是「執行理由」問題。論壇上有人從 Console 抓到
  `liveactivitiesd: Process is only playing background media so is forbidden to update activity`（thread 748569），
  Apple DTS 也回「背景更新只有推播是支援的做法，除非 App 在前景」（thread 776031）；另有 iOS 26.0.1 的 Loop（藍牙背景模式）
  在螢幕關閉時本機更新照樣送到 CarPlay（thread 804483）。所以 build 40 做三件事來量清楚：
  (1) 被擋期間的探測依 15→30→60→120 秒節奏調整並分級統計（`LiveActivityCadencePolicy`）；
  (2) 每次更新帶接下來幾句的視窗與起訖時刻（`LiveActivityWindowPolicy`），畫面用系統推進的進度條標出唱到哪；
  (3) 進背景時申請一次 `beginBackgroundTask`（約 25 秒），看有背景任務撐著時更新是否被套用。
  結論看下一份實測紀錄的「背景送出」與「背景任務」兩行。

- 第八輪（2026-09-23，build 41）：**重做背景定位實驗，這次量得清楚。** 查證：
  - Apple 文件 `allowsBackgroundLocationUpdates`：在前景開始定位更新後「Core Location configures the system to keep the app
    running to receive continuous background location updates」，「使用 App 期間」授權就夠（背景時狀態列有藍色定位指示）。
  - Apple 文件 `pausesLocationUpdatesAutomatically`：「使用 App 期間」的 App 要持續收到更新，建議關掉自動暫停並用
    `kCLLocationAccuracyThreeKilometers`（省電）。`CLBackgroundActivitySession`（iOS 17+）：「keeps your app in use in the background」，
    需要 `UIBackgroundModes` 含 `location`（WWDC23 10180）。
  - 開發者論壇 thread 717701：同一支 App 用背景定位或子母畫面時，背景更新即時動態正常；只有 `.playback` 背景音訊被擋。
  - 做法：設定「鎖定時也更新歌詞（使用定位）」（預設關）。只在連著 CarPlay（或按過「現在顯示」）且即時動態進行中時，
    在前景開 `CLLocationManager`（3 km 精準度、不自動暫停、`allowsBackgroundLocationUpdates`）+ `CLBackgroundActivitySession`；
    下車、即時動態結束、登出、關設定就停。位置不記錄、不上傳。決策在 `LocationKeepAlivePolicy`（Core，100% 測試）。
  - 量法：每次送出即時動態更新都記在當時的執行理由底下（前景／音訊／背景任務／定位，`LiveActivityReasonStats`），
    診斷頁「理由統計」與快照的「定位結論」直接寫出「定位保活期間全部被套用／全部被擋」。定位保活開始時會解除「背景被擋」，
    逐句更新立刻重新嘗試，不用等探測慢慢加快。

- 第十輪（2026-09-23，build 45 實測 → build 46）：**CarPlay 儀表板約每分鐘才重畫一次即時動態**，即使 App 在前景、
  每句更新都被系統套用（理由統計 前景 套用 58 擋 0）。Apple 文件 / WWDC25 216 / WWDC26 223 都沒有寫 CarPlay 的重畫節奏
  （216 只說「your app should only communicate the most significant states」）。做法：
  - `.small` 畫面改成「卡拉 OK 視窗」：目前句 + 接下來最多 5 句（`ViewThatFits` 放得下幾列就幾列），每一列底下一條
    `ProgressView(timerInterval:countsDown: false)`（Apple 文件：fills as time passes），空的＝還沒到、在走＝正在唱、滿的＝唱過了，
    完全不需要 App 更新；視窗拉長到 75 秒 / 最多 6 句、每句截到 40 字（4 KB 上限有測試）。
  - 逐句 `Activity.update` 保留：鎖定畫面每句都會重畫（實測 stale 幾乎沒發生），每次更新的視窗也讓 CarPlay 下一次重畫時
    從當下那句開始。一次更新約 1 KB 的 XPC，代價很小。
  - 量法：小工具 extension 在畫面 body 記下重畫時刻（每個 family 一份，5 秒內合併，最多 40 筆，`LiveActivityRenderStore`），
    診斷頁「CarPlay 重畫間隔（small）：最近 N 次，平均／最長 X 秒」直接寫出節奏。
  同一份實測還修了：上車 / 即時動態開始 / 回前景 / 重新輪詢時閒置計時重新起算（原本 33 分鐘前的閒置讓即時動態 1 秒後就被收掉）；
  CarPlay 路由閃斷（離開 10–20 秒又回來）先等 30 秒寬限再收；暫停後 Spotify 回 204、同一首 30 分鐘內回來不當成換歌
  （歌詞沿用、不重載）；車上「沒在播放」前 2 分鐘每 5 秒問一次；上車時 App 在背景、即時動態開不了（"Target is not foreground"）
  就送本機通知「點一下開始顯示 CarPlay 歌詞」（只出現在 iPhone：Apple 文件 `allowInCarPlay` 說要 CarPlay 授權才會上車機螢幕）；
  「即時動態已開始（…背景）」在前景被記成背景是因為 `UIApplication.applicationState` 比 scenePhase 慢，改用 scenePhase。

## 小工具「每句一個 timeline entry」

- Apple 文件：timeline entry 之間應該至少約 5 分鐘。實測 CarPlay 小工具不會照幾秒一次的 entry 換句。
- 現在的做法：App 換句時呼叫 `reloadTimelines`（前景不計額度；背景有音訊工作階段時文件說不計額度），並由 `WidgetReloadPolicy` 監督，被節流時自動改用段落模式。

<!-- rebuild 2026-09-24: release asset missing after run 48 -->
