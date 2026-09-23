# 試過但沒用的做法

## 背景定位讓即時動態在背景持續更新（2026-09，已移除）

- 想法：iOS 會擋掉「只播放背景音訊」的 App 在背景更新即時動態；加上 `CLLocationManager` 背景定位（最低精準度 + `CLBackgroundActivitySession`），也許系統就不會把 App 當成單純的音訊 App。
- 做法：`LocationKeeper`（`kCLLocationAccuracyThreeKilometers`、`allowsBackgroundLocationUpdates`），Info.plist 加 `location` 背景模式與兩段定位權限說明。
- 結果：實測 debug.log 顯示定位啟動後，鎖定期間的即時動態更新仍然「沒有被系統套用」。沒效又多一個定位權限，整組移除。
- 復原：參考 commit `68ac5f2`（CI #13）。
- 注意：上面「背景更新被擋」的結論是在 CI #31 修正即時動態驗證的競態（送出後太快讀回 `activity.content`，把還沒套用的更新誤判成被拒絕）**之前**量到的，當時的「沒有被系統套用」可能有一部分是驗證本身的誤判。這個結論要用修正後的版本（診斷頁的接受／拒絕次數）重新實測才算數；重新量之前不要拿它當依據。
- 實測結果（驗證修正後）：尚未重新量測，待補。

## 小工具「每句一個 timeline entry」

- Apple 文件：timeline entry 之間應該至少約 5 分鐘。實測 CarPlay 小工具不會照幾秒一次的 entry 換句。
- 現在的做法：App 換句時呼叫 `reloadTimelines`（前景不計額度；背景有音訊工作階段時文件說不計額度），並由 `WidgetReloadPolicy` 監督，被節流時自動改用段落模式。
