<p align="center">


  <img src="Design/App_Icon_Mac_Master.png" alt="Wisp 應用圖示" width="120" height="120">
</p>

<h1 align="center">Wisp</h1>

<p align="center">
  <strong>一個原生 macOS AI 助手：你問的時候，它才讀你的螢幕和瀏覽器。</strong>
</p>

<p align="center">
  <a href="https://github.com/ycl-2004/Wisp/releases/latest"><img src="https://img.shields.io/github/v/release/ycl-2004/Wisp?label=release&color=111111" alt="最新發佈"></a>
  <a href="https://github.com/ycl-2004/Wisp/releases"><img src="https://img.shields.io/github/downloads/ycl-2004/Wisp/total?label=downloads&color=111111" alt="下載總數"></a>
  <img src="https://img.shields.io/badge/macOS-14.0%2B-111111?logo=apple&logoColor=white" alt="需要 macOS 14.0 或更高">
  <img src="https://img.shields.io/badge/Mac-Universal%202-111111?logo=apple&logoColor=white" alt="Apple Silicon 與 Intel 通用">
  <img src="https://img.shields.io/badge/Swift-SwiftUI%20%C2%B7%20AppKit-F05138?logo=swift&logoColor=white" alt="SwiftUI 與 AppKit 建構">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-111111" alt="MIT 許可證"></a>
</p>

<p align="center">
  <a href="https://github.com/ycl-2004/Wisp/releases/latest/download/Wisp-macOS-universal.zip"><strong>⬇ 下載 macOS 版</strong></a>
  ·
  <a href="https://github.com/ycl-2004/Wisp/releases">釋出頁</a>
  ·
  <a href="#功能">功能</a>
  ·
  <a href="#隱私">隱私</a>
  ·
  <a href="#從原始碼建構">從原始碼建構</a>
  ·
  <a href="README.md">English</a>
</p>

Wisp 常駐選單欄。按下 `⌃⌥Space`，它會先記住此刻最前面的那個應用，然後才把面板顯示出來。
接著它會擷取當前視窗（也可以設成截整個螢幕）；如果最前面的是支援的瀏覽器，還會讀出網址、標題、選中的文字和整頁正文。
不用再在兩個應用之間來回複製貼上。

它是一層本地優先的桌面外殼，模型由你自己選：OpenAI 相容介面、Ollama，或者 Agent CLI（包含 Codex、Antigravity 與 Claude Code）。
對話文字和頁面文字快照存在你自己的 Mac 上；本地 CLI 可能把當次截圖寫進一個私有臨時目錄，命令結束後由 Wisp 刪除。
介面提供簡體中文和英文，跟隨系統語言。

> **當前分發狀態：** 最新版本是 `v0.4.0 (build 6)`，Universal 2 建構，含 `arm64` 與
> `x86_64`。釋出包是 ad-hoc 簽名、未經 Apple 公證，
> 首次開啟可能需要按住 Control 點選 → **開啟**。

> **會被髮出去的東西：** 用雲端介面時，你正在看的那一頁的**整頁正文**和當前視窗（或整個螢幕）的**截圖**
> 會發到你配置的地址。排除機制是按應用而不是按站點的 —— 詳見 [PRIVACY.md](PRIVACY.md)。


輸入框上方可選擇「快速／深入」，預設是快速。在「設定 → 模型」中分別指定兩種模式的模型和快捷鍵；回答過程中仍可修改，下次提問生效。快速模式跳過新的整頁正文擷取，直接用預設模型；深入模式在支援時提高推理力度，在 Antigravity 上自動換成預設模型的 High 思考檔。兩種模式都優先請求可用的 Fast。快速模式的回答旁邊有「深入重答」，一鍵用深入模式替換這條回答，不多佔一輪。秒錶顯示準備、首字及總耗時。深入不代表答案已經驗證；詳見[模式、加速與準確性驗證](docs/model-speed.md)。

「設定 → 指令」裡存著常用指令（例如「總結這一頁」「翻譯選中內容」），每條可以指定自己的回答模式和快捷鍵，在輸入框旁的 ✦ 選單、空白對話裡或任何應用裡用快捷鍵都能觸發。輸入框裡寫了的文字會作為材料跟在指令後面。

## 即時聽懂

語音輸入和 AI 對話共用一個面板：一行即時字幕，左邊是錄音狀態和已錄時長，右邊是
「停止並分析」，其餘動作收在 ⋯ 選單裡。音源、應用、語言和儲存選項集中在
「設定 → 音訊」，那裡也有一個總開關：關掉之後面板上不再有語音這一行，快捷鍵也不會
再開始錄音。⌃⌥R 開始／停止，停止後把最近轉寫放進輸入框；⌃⌥D 可在錄音時放入
草稿，編輯後按 Enter 傳送。會議剛結束想直接要結論，⌃⌥↩ 一個鍵停止錄音、等末尾文字
收完再發出去；⌃⌥A 則是不停止錄音直接分析。旁邊還有一個按鈕，在「AI 回答」和
「這次的轉寫原文」之間切換。除這些動作外不會自動傳送，也不發完成通知。
「設定 → 資料 → 錄音記錄」可獨立清理；2 GiB / 100 次容量限制保留。隱藏面板仍會停止錄音。

「設定 → 音訊 → 識別引擎」除了 Apple Speech，還會列出 `~/Documents/huggingface/models/`
裡找到的本地 sherpa-onnx 模型（目前識別 SenseVoice 和 Qwen3-ASR 兩種架構）。再放進一個
模型資料夾，點「重新掃描」就能選，不需要重灌 Wisp。本地模型的中文預設統一成簡體（Qwen3-ASR 有時會寫繁體），
可在「設定 → 音訊 → 中文字形」裡改。詳情見[識別引擎說明](docs/live-listening.md#recognition-engines)。

「按住說話提問」（設定 → 音訊 → 快捷鍵，預設未設定）：按住快捷鍵說出問題，鬆開後連同當前螢幕上下文，
用當前回答模式直接傳送。只用麥克風，不寫進錄音記錄；錄音進行中不可用。按一下不到 0.3 秒不會傳送；
超過 60 秒則只放進輸入框、不自動傳送。

裝置需要支援所選語言的本地識別；不支援時會提示，不會自動上傳音訊。
採集按應用選擇，不能直接區分某個參會人或瀏覽器標籤頁，也不保證錄音不可檢測。
錄製前請取得必要同意。詳見[操作、儲存上限和驗證範圍](docs/live-listening.md)。


如果選單欄圖示不見了，可從訪達或 Spotlight 再開啟 Wisp，面板上的齒輪始終可進入設定。
主動隱藏由「設定 → 隱私」控制；系統移除不再改寫這個偏好，異常移除會嘗試恢復一次，
再次移除則打開面板兜底。全屏隱藏、選單欄空間不足和第三方選單欄管理工具仍受系統或該工具控制。

## 快速開始

1. **[下載 `Wisp-macOS-universal.zip`](https://github.com/ycl-2004/Wisp/releases/latest/download/Wisp-macOS-universal.zip)** 並解壓。
2. 把 `Wisp.app` 拖到 `~/應用程式` 或 `/應用程式`。
3. 首次啟動請按住 Control 點選 `Wisp.app`，選擇**開啟**並確認。釋出包未公證，直接雙擊可能被 Gatekeeper 攔下。
4. 在系統設定裡授予**螢幕錄製**權限。第一次讀取瀏覽器頁面時，再授予 Wisp 對該瀏覽器的**自動化**權限。
5. 開啟**設定 → 模型**，選一種接法（改動自動儲存），點**測試連線**。
6. 切回你想提問的那個視窗，按 `⌃⌥Space`。

如果沒有出現 Control 點選 → **開啟** 的選項，清掉隔離標記：

```bash
xattr -dr com.apple.quarantine "$HOME/Applications/Wisp.app"
open "$HOME/Applications/Wisp.app"
```

### 系統要求

- macOS 14.0 或更高。
- Apple Silicon 或 Intel Mac。釋出包是 Universal 2。
- 擷取當前視窗或整個螢幕需要**螢幕錄製**權限。
- 讀取瀏覽器整頁正文需要**自動化**權限，以及瀏覽器裡的 `Allow JavaScript from Apple Events` 開關。
- 雲端介面需要聯網和你自己的 API Key。
- Ollama 接法需要本機已經跑起 Ollama 服務。
- Agent CLI 接法需要本機裝好並已登入的 Codex CLI、Antigravity CLI 或 Claude Code。

## 為什麼是 Wisp

- **上下文在面板出現之前就採集好了。** Wisp 先記住目標應用，所以助手面板不會把自己截進去。
- **請求邊界是看得見的。** 頭部會顯示當前應用、瀏覽器資訊、截圖與整頁文字的狀態，以及對話計數。
- **採集是按需的。** 常駐的小藥丸只跟蹤當前是哪個應用，不持續錄屏，也不跑瀏覽器指令碼。
- **模型連線是你自己的。** 雲端相容介面、本地 Ollama 模型，或者你已經登入的 Agent CLI（Codex、Antigravity 或 Claude Code）。
- **保留多久由你說了算。** 對話數與輪數上限可配置，刪除由你發起，沒有藏起來的自動清理。

## 功能

**螢幕與瀏覽器上下文**

- 擷取當前最前面應用的視窗；截圖通常只留在記憶體裡。
- 也可以改成截焦點視窗所在的整塊螢幕，一次問好幾個視窗。排除的應用和你勾選的應用會從畫面裡挖掉。
- 支援 Chrome、Brave、Edge、Vivaldi、Yandex、Opera、Safari、Arc，以及部分穩定版／測試版的 bundle id。
- 從支援的瀏覽器讀取當前網址、頁面標題、選中文字和整頁正文。
- 會報告跨域 iframe 的地址和讀不到的正文，免得模型以為整頁都讀到了。
- JavaScript 開關沒開、或當前應用不受支援時，明確退回到「只有網址和截圖」。
- 虛擬滾動頁面採集結束後會清理臨時的 `window.__wispCollector`；Wisp 只讀取
  Chromium 偏好來判斷 Apple Events 開關，不會把 Wisp 資料寫進瀏覽器配置、歷史或快取。

**浮動面板與小藥丸**

- 選單欄應用，沒有常規的 Dock 視窗。
- 起始是一張緊湊卡片，需要時向上展開；對話區在有限高度內滾動。
- 支援拖動、縮放、Esc 收起，以及離開面板後自動收起。
- 可選登入時自動啟動，重啟之後藥丸還在。
- 常駐小藥丸顯示當前應用與上下文狀態。桌面形態下可以拖到螢幕任意位置並被記住；拖動時它會收成一顆小圓跟著遊標走，所以貼得到螢幕邊緣。展開時朝有空間的一側長，而不是永遠從中間往兩邊撐。也可以改成吸附在劉海上。
- 提供簡體中文與英文。預設跟隨系統語言，也可以在「設定 → 通用」裡單獨釘死一種。

**螢幕共享隱藏（盡力支援）**

- 新增[原生能力研究與擴充套件測試](docs/screen-privacy-research-20260910.md)，覆蓋獨立捕獲程式、
  錄製中切換過濾器、系統影片錄製，以及受保護影片層和專用共享視窗等替代方案。
  說明氣泡、上下文與耗時詳情、許可說明頁在掛載到視窗時應用隱藏偏好，減少時機缺口；
  這不改變下面的系統能力邊界。
- 預設開啟，通過 `NSWindow.sharingType = .none` 請求隱藏視窗，本機仍可使用 Wisp。
  Apple 已將它列為舊機制，並明確要求不要依賴它阻止捕獲；具體效果取決於 macOS
  和錄屏方式，開關開啟不代表接收端已經看不到 Wisp。
- 選單欄裡的「嘗試在螢幕共享時隱藏」可以直接開關，也可以走「設定 → 權限 → 螢幕共享」。
  要錄製 Wisp 演示時請關閉。
- 在 macOS 26.6.1 的本地測試中，使用 Wisp 生產隱藏程式碼的合成視窗沒有出現在
  ScreenCaptureKit 整屏截圖和影片幀中，但仍出現在可捕獲視窗列表裡。
  這不代表 Chrome、Zoom、Meet、飛書、Teams、OBS 或監考平臺都經過驗證。
  詳見[測試範圍、結果與復現步驟](docs/screen-privacy-validation.md)。
- 選單欄圖示、系統彈窗不保證隱藏。這一設定不隱藏應用身份、焦點變化、剪貼簿事件
  或第三方的行為記錄，也不影響攝像機拍屏和硬體採集。使用前請檢查實際接收端畫面。
- **隱私遊標鎖定（實驗）。** 在「設定 → 權限 → 螢幕共享」中開啟後，先隱藏系統指標，再顯示
  一個跟隨滑鼠的本地私有箭頭。已移除共享靜止箭頭，避免它從透明或移動的視窗下露出，形成
  雙滑鼠。同時統一文本、控制元件和縮放邊緣的箭頭樣式，並關閉自定義按鈕及普通按鈕
  的按壓特效。關閉後恢復原生遊標請求和按鈕反饋。受保護的面板、設定標題欄、非焦點浮窗以及
  本程式選單、氣泡使用相同策略，原生拖動持續到鬆手。後臺懸停保留系統指標，點選時先啟用
  Wisp 再鎖定，並儲存原外部採集目標；本機保留文字選區、輸入遊標與選單選中提示，
  點選、輸入、選區、滾動保持原生行為。這些提示隨所屬視窗一起向相容錄屏請求隱藏。
  預設關閉；開啟時同時開啟視窗隱藏，關閉視窗隱藏也關閉鎖定，單獨關閉鎖定則保留視窗隱藏。
  **錄屏工具仍可能獨立繪製點選圓圈或傳輸滑鼠座標。** 點選提示需在錄製工具中關閉，Wisp 無法
  修改其他 App 的錄製流。相容錄屏在操作 Wisp 時省略滑鼠，不再人為補畫靜止箭頭。
  詳見[單遊標修復驗證](docs/single-cursor-20260912.md)。
- **縮放提示。** 面板內側新增一圈圓角淡藍色細線，以及四條邊中間的小標記，提示自定義
  縮放的可拖拽位置。它只負責提示，不會攔截點選；開啟隱私遊標鎖定時，縮放遊標保持箭頭。

**快捷鍵**

- 預設的 `⌃⌥Space` 仍然可用，也可以在「設定 → 權限」裡修改。增強模式支援
  `Shift`、`Globe/Fn`、單獨修飾鍵，以及雙擊/三擊同一個鍵。增強模式需要輔助功能權限，
  才能在其他 App 活躍時觀察鍵盤事件。

**模型接法**

- **雲端介面：** 以 SSE 流式傳送 `chat/completions`，圖片走 `image_url` data URL，相容 OpenAI、OpenRouter 等。
- **Ollama：** 預設 `http://localhost:11434/v1`，直接讀本機模型列表，並標出看起來支援讀圖的模型。
- **Agent CLI：** 同一個設定分組裡可以選 Codex、Antigravity 或 Claude Code。Codex 執行本機的 `codex app-server --listen stdio://`，建立臨時、只讀的會話；Antigravity 和 Claude Code 使用各自的 headless `stream-json`。三者都隨文字增量重新整理答案，截圖通過私有臨時工作目錄傳入，都不往 Wisp 的對話目錄裡寫會話檔案。協議與驗證見 [CLI 流式接入說明](docs/cli-streaming.md)。
  支援的 Codex 模型和 Claude Opus 選項預設優先 Fast，不可用時回到普通速度；AGY 1.1.27 沒有 Fast 開關。Fast 可能增加額度消耗，不降低思考強度，也不替換所選模型。

**啟動與更新**

- 可選的登入時自啟，走 `SMAppService`；被系統攔下待批准時，設定裡會直接給出「登入項與擴充套件」的入口。
- 可選的更新檢查：每次啟動向 GitHub 問一次最新版本號。預設關閉，不傳送任何關於你或你使用情況的資訊，不會自行下載或安裝，也可以完全關掉。

**本地對話**

- 預設最多 10 個對話、每個對話 30 輪；兩個上限都可以在設定裡改。
- 最近兩輪保留完整上下文，更早的摺疊成摘要行。
- 頁面正文上限 60,000 字，超出時保留頭 75% 與尾 25%。
- 對話以可讀 JSON 儲存，並且是容錯解碼的：某條記錄壞掉、或者將來的版本加了欄位，代價是丟那一條，而不是整份歷史。
- 拒絕覆蓋由更新版本 Wisp 寫出的對話檔案；檔案讀不出來時會明確告訴你，而不是悄悄從空白開始。
- 到達對話上限時，會點名問你要不要頂掉最久沒更新的那個，而不是直接不讓新建。
- 設定裡可以一次性刪除全部對話與已儲存的 API Key。

## 用法

### 問一個問題

```text
⌃⌥Space
  ↓ 記住當前最前面的應用
  ↓ 擷取視窗；可用時讀取瀏覽器網址、標題與整頁正文
  ↓ 顯示面板並標出這次採集到的上下文
  ↓ 提問 → 發給選定的接法
  ↓ 回答完成後把對話留在本機
```

### 快捷鍵與控制元件

| 操作 | 預設行為 |
| --- | --- |
| `⌃⌥Space` | 喚起或收起面板；可在設定裡改 |
| `⌘↩` | 傳送 |
| `⌘.` | 停止生成 |
| `Esc` | 收起面板 |
| 頭部 `∧` / `∨` | 在緊湊卡片與展開面板之間切換 |
| 頭部 `↻` | 重新讀取當前上下文 |
| **截圖**標籤 | 決定這次請求帶不帶截圖 |
| **說明**標籤 | 解釋這次採集到了什麼 |
| 對話氣泡按鈕 | 開啟對話列表 |

Wisp 會在三個時機重新整理上下文：面板顯示時、面板開著而最前面的應用變了時，以及傳送前發現上次採集
已經超過 20 秒或你離開過面板時。回答正在生成時不會自動重新採集。

### 選擇接法

選單欄圖示 → **設定 → 模型**：

- **雲端介面：** 先選服務商 —— OpenRouter、Google Gemini、OpenAI、Anthropic、智譜 GLM，
  或者「自定義」填任意 OpenAI 相容地址 —— 再選模型、填這一家的 API Key。
  選了服務商，Base URL 和模型列表會自動帶出來。Key 會在輸入框失焦、按回車、切換服務商或
  關閉設定時儲存，並按服務商分開放在 macOS 鑰匙串，不寫進對話 JSON，所以幾家可以同時配好隨時切。
- **Ollama：** 啟動 Ollama 後重新整理模型列表。只有能讀圖的模型才看得懂截圖。
- **Agent CLI：** 在同一個分組裡選擇 Codex、Antigravity 或 Claude Code，再選檢測到的執行檔和模型。用的是你 Mac 上已有的 CLI 登入。Antigravity 模型列表每次通過 `agy models` 重新掃描，Antigravity 自己更新後不需要改 Wisp。

三種接法都有**測試連線**。雲端和 Ollama 的測試會給快速、深入實際使用的模型各發一張很小的測試圖；Codex 與 Antigravity
檢查 `--version`，Claude Code 檢查 `auth status`，因此未登入會得到單獨提示。本地 CLI 的檢查都不消耗模型請求。

## 隱私

**本地儲存**

- 對話文字與頁面文字快照：`~/Library/Application Support/Wisp/conversations.json`。
- 即時聽懂：文字、時間和可選音訊儲存在 `~/Library/Application Support/Wisp/Listening/`，無自動歷史淘汰。
- API Key：存在 macOS 鑰匙串，不在 Wisp 的應用支援目錄裡。
- 截圖：不會寫進對話 JSON。雲端和 Ollama 只保留在記憶體；本地 CLI 可能寫入權限為 `0700`
  的當次臨時目錄，命令結束後刪除。若應用崩潰或被強制終止，則交由 macOS 後續清理臨時目錄。
- 可選的除錯檔案：開啟除錯採集後，會在應用支援目錄下寫 `debug/last-context.json` 與 `debug/last-screenshot.jpg`。

**網路邊界**

- 雲端介面會把你選定的上下文和當前截圖發到你配置的 Base URL。對方的日誌、留存策略和隱私條款不在 Wisp 的控制範圍內。
- Ollama 預設走 `localhost`。如果你把 Base URL 指到遠端，請求就會發到那裡。
- Codex 接法由 Wisp 啟動獨立的本地 app-server 程式，為圖片輸入建一個臨時目錄，以 `ephemeral: true`、只讀沙箱和 `approvalPolicy: never` 建立會話；回答結束後關閉程式並刪除目錄。Codex 自己的帳號、網路和服務端日誌不在 Wisp 的控制範圍內。
- Antigravity 接法由 Wisp 啟動本地 `agy` 程式，帶 `--sandbox`，跑在自己的臨時工作目錄裡，走 Antigravity 的 JSON headless 模式。有截圖時，截圖寫進這個目錄並在提問裡點名路徑，由 Antigravity 自己讀取；請求結束就把目錄刪掉。Antigravity 自己的帳號、網路、額度和服務端日誌不在 Wisp 的控制範圍內。
- Claude Code 接法跑在自己的臨時工作目錄裡，使用 `--restricted --tools Read --no-session-persistence`。檔案工具只能看到這個工作目錄裡的截圖，不會儲存本地會話記錄；請求結束後刪除目錄。Claude Code 自己的帳號、網路、額度和服務端日誌不在 Wisp 的控制範圍內。
- 開啟更新檢查時，Wisp 每次啟動向 `api.github.com` 請求一次最新版本號。除了 IP 和 `Wisp/<版本>` 這個 UA 之外不帶任何標識，不下載也不安裝。關掉就完全不請求。
- Wisp 沒有帳號體系、同步服務、統計 SDK、崩潰上報 SDK，也沒有後臺持續錄製。

**排除是按應用、不是按站點的。** 排除列表填的是 bundle id，所以目前沒有辦法在繼續使用某個瀏覽器的
同時，單獨豁免某一個網址或域名。整屏截圖會挖掉排除的應用，以及你在「設定 → 採集 → 截圖範圍」裡勾選的應用。

完整條款見 [PRIVACY.md](PRIVACY.md)。

**權限**

- **螢幕錄製：** 擷取當前視窗或整個螢幕。
- **自動化 / Apple Events：** 讀取瀏覽器網址與標題，以及在支援的瀏覽器裡執行取文指令碼。
- **網路客戶端：** 雲端介面、遠端 Ollama，或 Codex 自身的網路行為。

## 當前版本

當前版本是 `0.4.0 (build 6)`，見 [CHANGELOG.md](CHANGELOG.md)，對應 Git 標籤
`v0.4.0`。

| 檔案 | 用途 |
| --- | --- |
| `Wisp-macOS-universal.zip` | 含 `arm64` 與 `x86_64` 的 macOS 應用 |
| `Wisp-macOS-universal.zip.sha256` | 該 ZIP 的 SHA-256 校驗值 |

Universal 2 包通過了兩個架構切片的 `lipo -info` 檢查。釋出驗證在 Apple Silicon 上完成，
Intel 硬體上的執行時迴歸尚未做。包是 ad-hoc 簽名、未經 Apple 公證，首次開啟可能需要
Control 點選 → **開啟**。

## 常見問題

<details>
<summary>怎麼移動小藥丸？怎麼改介面語言？</summary>

按住藥丸拖動，就能把它放到桌面上任何位置。拖動時它會收成一顆小圓並跟著遊標走，所以可以一直推到螢幕
邊緣；重新展開時會朝還有空間的那一側長，而不是永遠從中間撐開。鬆手即記住，重開也在那兒；
顯示器佈局變了會被拉回屏內。
**設定 → 螢幕與權限 → 回到預設位置** 可以放回底部居中，同一段裡也可以切換成吸附劉海的形態
（劉海形態固定在劉海上，不可拖動）。拖動藥丸不會影響助手面板 —— 面板仍然從底部中間展開，
並且記住它自己的位置。

Wisp 提供簡體中文和英文，預設跟隨系統語言。想不管系統設定、固定用某一種語言，開啟
**設定 → 通用 → 介面語言** 選一個即可；Wisp 會提示重啟，重開之後生效。這個設定隻影響
Wisp 自己，不會動你的系統設定。

也可以在終端裡改：

```bash
defaults write com.yichenlin.Wisp AppleLanguages -array zh-Hans
```

換成 `en` 即為英文；`defaults delete com.yichenlin.Wisp AppleLanguages` 可以恢復跟隨系統。
改完請重啟 Wisp。

</details>

<details>
<summary>升級之後讀不到螢幕了，或者又要重新授權</summary>

釋出包是 ad-hoc 簽名的，也就是說每次建構的程式碼身份都不一樣。macOS 把螢幕錄製、自動化和鑰匙串
存取都綁在這個身份上，所以新版本可能被當成另一個應用，拿不到舊版本的授權。請到「系統設定 →
隱私與安全性」重新勾選螢幕錄製，下次讀取網頁時重新允許對瀏覽器的自動化，鑰匙串彈窗如果被拒
則重新填一次 API Key。順手把列表裡舊建構那條陳舊記錄刪掉會清爽一些。

等釋出改用 Developer ID 證書籤名並公證之後，這個問題就沒有了。自己建構、自己每天用的那一份
現在已經不用忍：`tools/install-local.sh` 用團隊證書籤名，程式碼身份在重建之間不再變化。

</details>

<details>
<summary>macOS 提示無法開啟，因為無法驗證開發者</summary>

公開建構是 ad-hoc 簽名、未經 Apple 公證的，Gatekeeper 可能攔下直接雙擊。按住 Control 點選
`Wisp.app`，選擇**開啟**並確認一次即可。如果沒有這個選項，執行[快速開始](#快速開始)裡的
`xattr` 命令。

</details>

<details>
<summary>瀏覽器裡只有截圖，讀不到整頁文字</summary>

整頁正文要靠向瀏覽器注入指令碼才能拿到，這需要兩件事：一是系統的**自動化**權限，二是瀏覽器自己的
`Allow JavaScript from Apple Events` 開關。Chromium 系的這個開關**每個配置檔案要各開一次**
（選單欄 View → Developer），Safari 在 Develop 選單裡且不分配置檔案。沒開的時候 Wisp 會明確
告訴你，並且只發網址和截圖。

</details>

<details>
<summary>Wisp 會一直錄我的螢幕嗎？</summary>

不會。採集只發生在你按快捷鍵、點重新整理，或者面板開著時你切到了別的應用這三種情況下。面板關著的時候
不採集。常駐的小藥丸只跟蹤當前是哪個應用，不截圖也不跑瀏覽器指令碼。

</details>

<details>
<summary>怎麼解除安裝 Wisp？</summary>

退出 Wisp，然後刪掉這些：

```bash
rm -rf "$HOME/Applications/Wisp.app"
rm -rf "$HOME/Library/Application Support/Wisp"
defaults delete com.yichenlin.Wisp
```

鑰匙串裡的 API Key 在「鑰匙串存取」裡搜 `com.yichenlin.Wisp` 刪除，或者解除安裝之前先在
**設定 → 資料 → 刪除全部對話與 API Key** 裡清掉。另外記得到「系統設定 → 隱私與安全性」裡
把螢幕錄製和自動化的條目也移除。

</details>

## 從原始碼建構

<details>
<summary>依賴、開發命令與 Universal 2 打包</summary>

依賴：

- macOS 14.0 或更高。
- Xcode 26.6（當前驗證環境），或其他提供 macOS 14 SDK 的相容版本。
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45.4 或更高，用於從 `project.yml` 重新生成 Xcode 工程。
- Swift Package Manager，按當前鎖定狀態解析 `KeyboardShortcuts` 2.4.0。

本地開發建構：

```bash
xcodegen generate
xcodebuild -project Wisp.xcodeproj -scheme Wisp -configuration Debug build
cp -R Build/Debug/Wisp.app "$HOME/Applications/"
```

裝成自己每天用的那一份（`/Applications/Wisp.app`），且**不丟系統授權**：

```bash
tools/install-local.sh              # 建構、按團隊證書籤名、安裝；驗證後清理臨時備份
tools/install-local.sh --no-install # 只建構和簽名
tools/install-local.sh --keep-backup # 可選：保留回滾備份
```

ad-hoc 簽名沒有證書鏈可以錨定，designated requirement 只能寫成 `cdhash H"…"`，
程式碼一改雜湊就變，macOS 會把它當成另一個程式，螢幕錄製／麥克風／語音識別的授權
每次更新都要重給。指令碼改用團隊證書籤名，requirement 變成
`identifier "com.yichenlin.Wisp" and anchor apple generic and certificate leaf…`，
跟程式碼內容無關，重建多少次都是同一個身份。證書每年輪換、名字裡的編號會變，
所以指令碼按團隊 ID 從鑰匙串裡挑證書，再用指紋簽名——鑰匙串裡可能還躺著別的帳號的
開發證書，按名字匹配會挑錯。第一次換成證書籤名仍要再授權一次，之後不會再問。
安裝指令碼只在替換和簽名校驗期間暫存舊包，預設校驗成功後立即清理；需要回滾時再加
`--keep-backup`。

**這份包不要拿去分發**：別人的機器上沒有你的開發證書，Gatekeeper 會直接拒絕。

打 Universal 2 釋出包（對外分發仍然是 ad-hoc，因此使用者每次更新都要重新授權）：

```bash
rm -rf Build
xcodebuild -project Wisp.xcodeproj -scheme Wisp -configuration Release \
  -arch arm64 -arch x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build

mkdir -p dist
lipo -info Build/Release/Wisp.app/Contents/MacOS/Wisp
ditto --norsrc -c -k --keepParent \
  Build/Release/Wisp.app \
  dist/Wisp-macOS-universal.zip
shasum -a 256 dist/Wisp-macOS-universal.zip > dist/Wisp-macOS-universal.zip.sha256
```

這裡使用 `--norsrc` 排除資源分叉和 AppleDouble `._` 檔案，也故意不加
`--sequesterRsrc`：後者會把資源分叉塞進一個 `__MACOSX` 目錄，使用者解壓後就會看到它。
這樣生成的壓縮包是乾淨的，而且往返之後簽名依然可以驗證。

診斷入口（`--dump-context`、`--show`、`--render-*`）同時要求 `DEBUG` 和顯式的
`WISP_DIAGNOSTICS`，普通 Debug 建構裡也沒有它們。釋出版或日常建構裡留著它們，
等於把已經拿到的螢幕錄製授權借給任何本地程式。要重新生成 README 裡的截圖，
請帶上這個編譯條件建構：

```bash
xcodebuild -project Wisp.xcodeproj -scheme Wisp -configuration Debug \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG WISP_DIAGNOSTICS" build

Build/Debug/Wisp.app/Contents/MacOS/Wisp --render-header docs/screenshots/context-header.png
Build/Debug/Wisp.app/Contents/MacOS/Wisp --render-island docs/screenshots/island-states.png
```

加上 `-AppleLanguages '(en)'` 或 `-AppleLanguages '(zh-Hans)'` 可以指定渲染哪種語言。

釋出驗證：

```bash
plutil -p Build/Release/Wisp.app/Contents/Info.plist
codesign --verify --deep --strict Build/Release/Wisp.app
codesign -d --entitlements :- Build/Release/Wisp.app
unzip -l dist/Wisp-macOS-universal.zip
shasum -a 256 -c dist/Wisp-macOS-universal.zip.sha256
```

</details>

## 目錄結構

- `Wisp/App/` — 應用入口、選單欄生命週期、全域快捷鍵，以及診斷入口。
- `Wisp/Capture/` — 螢幕採集、瀏覽器 AppleScript、頁面取文與上下文編排。
- `Wisp/LLM/` — OpenAI 相容 HTTP、Ollama、Agent CLI、SSE 解析與提示片語裝。
- `Wisp/Store/` — 本地對話 JSON 與 macOS 鑰匙串存取。
- `Wisp/UI/` — 浮動面板、常駐藥丸、對話、上下文頭部、對話列表與設定。
- `Wisp/Support/` — 權限、螢幕幾何、UserDefaults 設定、登入項與更新檢查。
- `Wisp/Resources/` — 字串目錄。
- `WispTests/` — CLI 隔離、事件與登入解析、提示詞截斷、完成狀態和臨時目錄清理測試。
- `Wisp/Assets.xcassets/` — macOS 應用圖示與圖片資源。
- `docs/screenshots/` — README 裡那幾張離線渲染的截圖。
- `project.yml` — XcodeGen 工程源、版本設定、依賴、本地化與簽名配置。
- `LICENSE`、`THIRD-PARTY-NOTICES.txt`、`PRIVACY.md`、`CHANGELOG.md` — 許可證、依賴宣告、隱私政策與釋出說明。第三方宣告在建構時從倉庫根目錄複製進 App 包。

## 版本與釋出

`project.yml` 是 `MARKETING_VERSION` 與 `CURRENT_PROJECT_VERSION` 的唯一來源；
`Wisp.xcodeproj` 由 XcodeGen 重新生成。當前的釋出約定是：

1. 在 `project.yml` 裡更新版本號或建構號。
2. 跑 `xcodegen generate`，並完成一次 Debug 或 Release 建構。
3. 要出分發包的話，驗證兩個架構切片、bundle 後設資料、簽名、ZIP 完整性和校驗值。
4. 打 `vX.Y.Z` 標籤，把 `Wisp-macOS-universal.zip` 和它的 `.sha256` 傳到對應的 GitHub Release。

`Build/`、`dist/`、Xcode 使用者狀態、診斷檔案和本地環境檔案都不進 Git。原始碼、圖示資源、
工程檔案、包解析結果和公開文件會被追蹤。

## 已知限制

- 當前公開包是 ad-hoc 簽名、未經 Apple 公證的。
- Universal 2 的兩個切片已經生成並檢查過，但當前釋出尚未在 Intel Mac 上實機跑過。
- 瀏覽器取文依賴受支援的 bundle id、自動化權限、瀏覽器 JavaScript 設定以及頁面本身的安全邊界。
- Codex 流式接入需要支援 app-server v2 協議的 CLI，已用 0.153.4 驗證；每次請求仍帶著 Codex 自己的固定上下文開銷。
- Antigravity 按 agent response 增量顯示答案，已用 1.1.27 驗證；只傳送最終結果的舊版本會在結束時顯示全文。每次請求仍帶上它自己的固定上下文開銷——此前測量在 Wisp 的內容之前約 30,400 token。Antigravity 的 headless 輸入只接受文字，會拒絕 `image_url` 內容塊，所以截圖是以檔案形式傳入的，帶截圖的請求要多花一輪讀取檔案的工具呼叫，代價約 1,150 token，而不是把圖內聯進上下文。Antigravity 還會在約 71,400 token 處靜默截斷自己的輸入，因此 Wisp 會先把提示壓進一個更小的預算並標註省略了什麼；遠超預設 60,000 字上限的頁面因此是「刪節後送達且寫明缺口」，而不是悄悄少一截。
- CI 已覆蓋單元測試、Universal 2 編譯、簽名驗證和 Release 權限檢查；仍沒有公開的公證與釋出簽名流水線。
- 因為釋出包是 ad-hoc 簽名，每次建構都是新的程式碼身份。macOS 把螢幕錄製、自動化和鑰匙串存取綁在這個身份上，所以升級之後可能需要重新授權。
- 應用排除是按 bundle id 的。沒有按網址或域名的排除，而後者恰恰是瀏覽器裡最有用的那種。
- 對話歷史以未加密 JSON 儲存，且不按時間淘汰。對話數和輪數有上限，但訊息位元組數沒有硬上限；每寫一條訊息都會整份重寫。即時字幕不會自動追加聊天訊息。
- 藥丸只有桌面形態可以拖動；劉海形態固定吸附在劉海上。
- 小圓能貼到螢幕邊緣但不能超出去，所以它的圓心最多停在距邊緣一個半徑（20pt）的位置。

## 致謝

Wisp 內建了 Sindre Sorhus 的
[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) 2.4.0，MIT 許可證。
完整宣告隨應用一起分發 —— **設定 → 通用 → 開源許可** —— 並作為
[THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt) 一起提交在倉庫裡。

其餘部分都是用 SwiftUI 和 AppKit 從頭寫的，沒有其他第三方依賴。

## 許可證

Wisp 版權所有 © 2026 YC，以 [MIT 許可證](LICENSE)釋出。

## 連結

- [GitHub 倉庫](https://github.com/ycl-2004/Wisp)
- [最新發佈](https://github.com/ycl-2004/Wisp/releases/latest)
- [全部發佈](https://github.com/ycl-2004/Wisp/releases)
- [Issues](https://github.com/ycl-2004/Wisp/issues)
- [釋出說明](CHANGELOG.md)
- [隱私政策](PRIVACY.md)
- [第三方許可](THIRD-PARTY-NOTICES.txt)
- [English README](README.md)
