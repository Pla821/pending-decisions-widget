param([string]$Title = '有選項框等你回答', [string]$Body = '', [string]$Url = '')
# 由 decision-log.mjs 在「選項框被問出來」時呼叫：跳一個 Windows 通知（停在螢幕上直到你關掉；點它開「待決定清單」網頁）。
# 失敗就算了，不影響任何對話。
try {
	[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
	[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
	function Esc([string]$s) { [System.Security.SecurityElement]::Escape($s) }
	$launch = if ($Url) { " activationType=`"protocol`" launch=`"$(Esc $Url)`"" } else { '' }
	$xml = "<toast scenario=`"reminder`"$launch><visual><binding template=`"ToastGeneric`"><text>$(Esc $Title)</text><text>$(Esc $Body)</text></binding></visual><audio src=`"ms-winsoundevent:Notification.Reminder`"/></toast>"
	$doc = New-Object Windows.Data.Xml.Dom.XmlDocument
	$doc.LoadXml($xml)
	$toast = New-Object Windows.UI.Notifications.ToastNotification $doc
	# 借用 Windows PowerShell 的通知身分（System32 資料夾的固定 GUID），不用註冊自己的 App ID
	$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
	[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
} catch { }
