# 試過但沒用的做法

## 背景定位讓即時動態在背景持續更新（2026-09，已移除）

- 想法：iOS 會擋掉「只播放背景音訊」的 App 在背景更新即時動態；加上 `CLLocationManager` 背景定位（最低精準度 + `CLBackgroundActivitySession`），也許系統就不會把 App 當成單純的音訊 App。
- 做法：`LocationKeeper`（`kCLLocationAccuracyThreeKilometers`、`allowsBackgroundLocationUpdates`），Info.plist 加 `location` 背景模式與兩段定位權限說明。
- 結果：實測 debug.log 顯示定位啟動後，鎖定期間的即時動態更新仍然「沒有被系統套用」。沒效又多一個定位權限，整組移除。
- 復原：參考 commit `68ac5f2`（CI #13）。
- 注意：上面「背景更新被擋」的結論是在 CI #31 修正即時動態驗證的競態（送出後太快讀回 `activity.content`，把還沒套用的更新誤判成被拒絕）**之前**量到的，當時的「沒有被系統套用」可能有一部分是驗證本身的誤判。這個結論要用修正後的版本（診斷頁的接受／拒絕次數）重新實測才算數；重新量之前不要拿它當依據。
- 實測結果（驗證修正後，build 36，iOS 26.6.1，iPhone 15 Pro，接著 CarPlay、充電中）：**確認被擋**。進背景 3–13 秒後開始「沒有被系統套用」，連續 8 次後進入「背景被擋」，77 秒後即時動態變成 stale；回到前景立刻恢復（「恢復正常」）。App 內同步完全正確（最晚 0.2 秒）。Apple 文件（Displaying live data with Live Activities）說背景可以 update / end，但實際上只靠背景音訊活著的 App 更新會被丟掉。
- 結論與做法（build 39）：$0 沒有背景更新的替代路徑（推播要伺服器與付費帳號），所以改成「開車模式」：接著 CarPlay 時讓 CarLyrics 留在前景（螢幕不自動關閉、可調暗），並把每次更新的 staleDate 設在「下一句開始 + 2 秒」——被擋時畫面到時自己把下一句升成目前句一次，播完改顯示「打開 CarLyrics」；CarPlay 小工具頁是鎖定後的備援（時間軸驅動，不受這個限制）。

## 小工具「每句一個 timeline entry」

- Apple 文件：timeline entry 之間應該至少約 5 分鐘。實測 CarPlay 小工具不會照幾秒一次的 entry 換句。
- 現在的做法：App 換句時呼叫 `reloadTimelines`（前景不計額度；背景有音訊工作階段時文件說不計額度），並由 `WidgetReloadPolicy` 監督，被節流時自動改用段落模式。
