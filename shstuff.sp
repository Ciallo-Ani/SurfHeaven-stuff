#include <sourcemod>
#include <ripext>
#include <shavit>

#define HEAVEN_MAPINFO_API "https://surfheaven.eu/api/mapinfo/"
#define HEAVEN_RECORDS_API "https://surfheaven.eu/api/records/"
#define HEAVEN_WRCPS_API   "https://surfheaven.eu/api/stages/"

#define MAX_RECORDS 1000
#define STAGES_LIMIT 70 // due to surf_classics3

enum struct recordinfo_t
{
	char sName[MAX_NAME_LENGTH];
	float time;
	int rank;
	int completions;
	char sDate[128];
}

char gS_Map[160];
char gS_SelectedMap[MAXPLAYERS+1][160];
ArrayList gA_RecordsInfo[TRACK_LIMIT];
ArrayList gA_StageRecordsInfo[STAGES_LIMIT];
bool gB_CurrentMapFetching = false;

// other map record
ArrayList gA_TempRecordsInfo[MAXPLAYERS+1][TRACK_LIMIT];
ArrayList gA_TempStageRecordsInfo[MAXPLAYERS+1][STAGES_LIMIT];
bool gB_OtherMap[MAXPLAYERS+1];
bool gB_Fetching[MAXPLAYERS+1];
Handle gH_FetchTimer[MAXPLAYERS+1];



public void OnPluginStart()
{
	LoadTranslations("shavit-common.phrases");

	RegConsoleCmd("sm_shm", Command_SurfHeaven_Mapinfo);
	RegConsoleCmd("sm_shtop", Command_SurfHeaven_Top);
	RegConsoleCmd("sm_shwr", Command_SurfHeaven_WR);
	RegConsoleCmd("sm_shwrcp", Command_SurfHeaven_WRCP);
}

public void OnClientPutInServer(int client)
{
	gB_OtherMap[client] = false;
	gB_Fetching[client] = false;
}

public void OnMapStart()
{
	GetCurrentMap(gS_Map, sizeof(gS_Map));

	for(int i = 0; i < TRACK_LIMIT; i++)
	{
		delete gA_RecordsInfo[i];
		gA_RecordsInfo[i] = new ArrayList(sizeof(recordinfo_t));
	}

	for(int i = 0; i < STAGES_LIMIT; i++)
	{
		delete gA_StageRecordsInfo[i];
		gA_StageRecordsInfo[i] = new ArrayList(sizeof(recordinfo_t));
	}

	SurfHeaven_GetCurrentMapRecords();
}

void SurfHeaven_GetCurrentMapRecords()
{
	gB_CurrentMapFetching = true;

	char sURL[512];
	FormatURL(sURL, sizeof(sURL), HEAVEN_RECORDS_API, gS_Map);
	HTTPRequest records = new HTTPRequest(sURL);
	records.Timeout = 600;
	records.Get(GetCurrentMapRecords_Callback);
}

public void GetCurrentMapRecords_Callback(HTTPResponse response, any value, const char[] error)
{
	if(response.Status != HTTPStatus_OK)
	{
		LogError("*SurfHeaven* 获取地图信息失败! 原因: %s", error);
		return;
	}

	JSONArray records = view_as<JSONArray>(response.Data);

	for(int i = 0; i < records.Length; i++)
	{
		JSONObject info = view_as<JSONObject>(records.Get(i));

		recordinfo_t cache;

		int track;

		WriteRecordsToCache(info, cache, track);

		gA_RecordsInfo[track].PushArray(cache);

		delete info;
	}

	delete records;

	SortRecords(gA_RecordsInfo, TRACK_LIMIT);

	SurfHeaven_GetCurrentMapWRCPs();
}

void SurfHeaven_GetCurrentMapWRCPs()
{
	char sURL[512];
	FormatURL(sURL, sizeof(sURL), HEAVEN_WRCPS_API, gS_Map);
	HTTPRequest records = new HTTPRequest(sURL);
	records.Timeout = 120; // SH自己限定了大小，关卡记录远远小于主线记录，即便是超大数据量的surf_beginner
	records.Get(GetCurrentMapWRCPs_Callback);
}

public void GetCurrentMapWRCPs_Callback(HTTPResponse response, any value, const char[] error)
{
	if(response.Status != HTTPStatus_OK)
	{
		LogError("*SurfHeaven* 获取地图信息失败! 原因: %s", error);

		DoneFetchRecords();

		return;
	}

	JSONArray records = view_as<JSONArray>(response.Data);

	for(int i = 0; i < records.Length; i++)
	{
		JSONObject info = view_as<JSONObject>(records.Get(i));

		recordinfo_t cache;

		int stage;

		WriteWRCPsToCache(info, cache, stage);

		gA_StageRecordsInfo[stage].PushArray(cache);

		delete info;
	}

	delete records;

	SortRecords(gA_StageRecordsInfo, STAGES_LIMIT);

	DoneFetchRecords();
}

void DoneFetchRecords()
{
	gB_CurrentMapFetching = false;

	Shavit_PrintToChatAll("*{darkred}SurfHeaven{default}* | {gold}获取完毕!{default} 输入{green}!shm{default}, {green}!shwr{default}, {green}!shwrcp{default}, {green}!shtop{default}以查询地图信息和记录");
}

public Action Command_SurfHeaven_Mapinfo(int client, int args)
{
	char sMap[160];

	if(args == 0)
	{
		GetCurrentMap(sMap, sizeof(sMap));
	}
	else
	{
		GetCmdArgString(sMap, sizeof(sMap));
	}

	char sURL[512];
	FormatURL(sURL, sizeof(sURL), HEAVEN_MAPINFO_API, sMap);
	HTTPRequest mapinfo = new HTTPRequest(sURL);
	mapinfo.Get(GetMapinfo_Callback, GetClientSerial(client));

	return Plugin_Handled;
}

public void GetMapinfo_Callback(HTTPResponse response, any value, const char[] error)
{
	int client = GetClientFromSerial(value);

	if(response.Status != HTTPStatus_OK)
	{
		Shavit_PrintToChat(client, "*{darkred}SurfHeaven{default}* 获取地图信息失败! 原因: %s", error);
		return;
	}

	char sJsonString[1024];
	response.Data.ToString(sJsonString, sizeof(sJsonString));

	if(strlen(sJsonString) < 10)
	{
		Shavit_PrintToChat(client, "*{darkred}SurfHeaven{default}* 无法获取该地图信息! 原因: 找不到该地图");
		return;
	}

	JSONArray tmp = JSONArray.FromString(sJsonString);
	JSONObject json = view_as<JSONObject>(tmp.Get(0));
	delete tmp;

	char map[160];
	json.GetString("map", map, sizeof(map));

	int tier = json.GetInt("tier");
	bool linear = (json.GetInt("type") == 0);
	int cps = json.GetInt("checkpoints");

	if(!linear)
	{
		cps += 1;
	}

	int bonuses = json.GetInt("bonus");

	char sAuther[64];
	json.GetString("author", sAuther, sizeof(sAuther));

	int completions = json.GetInt("completions");

	Shavit_PrintToChatAll("*{darkred}SurfHeaven{default}* | 地图: %s, 难度: %d, %s: %d, 奖励: %d, 作者: %s, 完成次数: %d", 
		map, tier, linear?"检查点":"关卡", cps, bonuses, sAuther, completions);

	delete json;
}

public Action Command_SurfHeaven_Top(int client, int args)
{
	if(args == 0)
	{
		if(gB_CurrentMapFetching)
		{
			Shavit_PrintToChat(client, "当前地图的记录{lightred}仍在获取中{default}, 请耐心等待...");

			return Plugin_Handled;
		}

		strcopy(gS_SelectedMap[client], sizeof(gS_SelectedMap[]), gS_Map);
		OpenMapRecordsMenu(client, false);

		return Plugin_Handled;
	}

	if(gB_Fetching[client])
	{
		Shavit_PrintToChat(client, "请等待{lightgreen}上一轮{default}的记录查询完毕...");

		return Plugin_Handled;
	}

	GetCmdArgString(gS_SelectedMap[client], sizeof(gS_SelectedMap[]));
	GetOtherMapRecords(client, gS_SelectedMap[client]);
	gB_Fetching[client] = true;

	Shavit_PrintToChat(client, "查询{lightgreen}其他地图{default}记录时会有{darkred}延迟{default}, 请稍后...");

	gH_FetchTimer[client] = CreateTimer(60.0, Timer_FetchFailTips, GetClientSerial(client));

	return Plugin_Handled;
}

public Action Timer_FetchFailTips(Handle timer, any data)
{
	int client = GetClientFromSerial(data);

	Shavit_PrintToChat(client, "{lightred}60秒钟{default}过去了, "...
		"你查询的地图{darkred}数据量过大{default}, "...
		"请亲自去官网查询: {green}https://surfheaven.eu/map/%s{default}", 
		gS_SelectedMap[client]);

	gH_FetchTimer[client] = null;
	gB_Fetching[client] = false;

	return Plugin_Stop;
}

void GetOtherMapRecords(int client, const char[] map)
{
	char sURL[512];
	FormatURL(sURL, sizeof(sURL), HEAVEN_RECORDS_API, map);
	HTTPRequest records = new HTTPRequest(sURL);
	records.Timeout = 60;

	DataPack dp = new DataPack();
	dp.WriteCell(GetClientSerial(client));
	dp.WriteString(map);

	records.Get(GetOtherMapRecords_Callback, dp);
}

public void GetOtherMapRecords_Callback(HTTPResponse response, DataPack dp, const char[] error)
{
	dp.Reset();
	
	int client = GetClientFromSerial(dp.ReadCell());

	char sMap[160];
	dp.ReadString(sMap, sizeof(sMap));

	delete dp;


	if(response.Status != HTTPStatus_OK)
	{
		Shavit_PrintToChat(client, "*{darkred}SurfHeaven{default}* 获取地图信息失败! 原因: %s", error);
		gB_Fetching[client] = false;
		return;
	}

	delete gH_FetchTimer[client];
	InitTempRecords(client);

	JSONArray records = view_as<JSONArray>(response.Data);

	if(records.Length > 0)
	{
		Shavit_PrintToChat(client, "*{darkred}SurfHeaven{default}* | 主线和奖励记录信息{green}获取成功{default}");

		for(int i = 0; i < records.Length; i++)
		{
			JSONObject info = view_as<JSONObject>(records.Get(i));

			recordinfo_t cache;

			int track;

			WriteRecordsToCache(info, cache, track);

			gA_TempRecordsInfo[client][track].PushArray(cache);

			delete info;
		}

		SortRecords(gA_TempRecordsInfo[client], TRACK_LIMIT);
	}
	else
	{
		Shavit_PrintToChat(client, "*{darkred}SurfHeaven{default}* | {lightred}没有主线和奖励记录...{default}");
	}

	delete records;

	GetOtherMapWRCPs(client, sMap);
}

void GetOtherMapWRCPs(int client, const char[] map)
{
	char sURL[512];
	FormatURL(sURL, sizeof(sURL), HEAVEN_WRCPS_API, map);
	HTTPRequest records = new HTTPRequest(sURL);
	records.Get(GetOtherMapWRCPs_Callback, GetClientSerial(client));
}

public void GetOtherMapWRCPs_Callback(HTTPResponse response, any value, const char[] error)
{
	int client = GetClientFromSerial(value);

	if(response.Status != HTTPStatus_OK)
	{
		Shavit_PrintToChat(client, "*{darkred}SurfHeaven{default}* 获取地图WRCP信息失败! 原因: %s", error);
		gB_Fetching[client] = false;
		return;
	}

	JSONArray records = view_as<JSONArray>(response.Data);

	if(records.Length > 0)
	{
		Shavit_PrintToChat(client, "*{darkred}SurfHeaven{default}* | 关卡记录信息{green}获取成功{default}");

		for(int i = 0; i < records.Length; i++)
		{
			JSONObject info = view_as<JSONObject>(records.Get(i));

			recordinfo_t cache;

			int stage;

			WriteWRCPsToCache(info, cache, stage);

			gA_TempStageRecordsInfo[client][stage].PushArray(cache);

			delete info;
		}

		SortRecords(gA_TempStageRecordsInfo[client], STAGES_LIMIT);
	}
	else
	{
		Shavit_PrintToChat(client, "*{darkred}SurfHeaven{default}* | {lightred}没有关卡记录...{default}");
	}

	delete records;

	gB_Fetching[client] = false;

	OpenMapRecordsMenu(client, true);
}



/* menu */

void OpenMapRecordsMenu(int client, bool othermap)
{
	gB_OtherMap[client] = othermap;

	Menu menu = new Menu(MapRecordsMenu_Handler);

	menu.SetTitle("SH记录查询: %s\n(以SH服务器区域为准)\n  ", gS_SelectedMap[client]);

	menu.AddItem("main", "主线记录");
	menu.AddItem("bonus", "奖励关记录");
	menu.AddItem("stage", "关卡记录");

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MapRecordsMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[16];
		menu.GetItem(param2, sInfo, sizeof(sInfo));

		if(StrEqual(sInfo, "main"))
		{
			OpenMainRecordsMenu(param1);
		}
		else if(StrEqual(sInfo, "bonus"))
		{
			OpenBonusRecordsMenu(param1);
		}
		else //if(StrEqual(sInfo, "stage"))
		{
			OpenStageRecordsMenu(param1);
		}
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void OpenMainRecordsMenu(int client)
{
	Menu menu = new Menu(MainRecordsMenu_Handler);

	menu.SetTitle("记录 %s: [主线] \n(只显示前1000)\n  ", gS_SelectedMap[client]);

	ArrayList arr = gB_OtherMap[client] ? gA_TempRecordsInfo[client][Track_Main] : gA_RecordsInfo[Track_Main];

	for(int i = 0; i < arr.Length; i++)
	{
		recordinfo_t cache;
		arr.GetArray(i, cache, sizeof(recordinfo_t));

		char sTime[32];
		FormatHUDSecondsEx(cache.time, sTime, sizeof(sTime));

		char sDisplay[128]
		FormatEx(sDisplay, sizeof(sDisplay), "#%d - %s - %s (%d 尝试次数)", cache.rank, cache.sName, sTime, cache.completions);
		menu.AddItem("", sDisplay, ITEMDRAW_DISABLED);
	}

	if(menu.ItemCount == 0)
	{
		menu.AddItem("", "惊了, SH无记录... \n(有没有一种可能, SH没有这个地图)", ITEMDRAW_DISABLED);
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MainRecordsMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
		{
			OpenMapRecordsMenu(param1, gB_OtherMap[param1]);
		}
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void OpenBonusRecordsMenu(int client)
{
	Menu menu = new Menu(BonusRecordsMenu_Handler);

	menu.SetTitle("请选择奖励关: \n(只显示有记录的奖励)\n  ");

	ArrayList arr[TRACK_LIMIT];
	arr = gB_OtherMap[client] ? gA_TempRecordsInfo[client] : gA_RecordsInfo;

	for(int i = 1; i < TRACK_LIMIT; i++)
	{
		if(arr[i].Length == 0) // this bonus has no records found.
		{
			continue;
		}

		char sInfo[4];
		IntToString(i, sInfo, sizeof(sInfo));

		char sTrack[32];
		GetTrackName(client, i, sTrack, sizeof(sTrack));

		menu.AddItem(sInfo, sTrack);
	}

	if(menu.ItemCount == 0)
	{
		menu.AddItem("", "没有奖励关记录, 或许这个图压根就没有奖励关? \n(有没有一种可能, SH没有这个地图)", ITEMDRAW_DISABLED);
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int BonusRecordsMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[4];
		menu.GetItem(param2, sInfo, sizeof(sInfo));

		OpenBonusRecordsMenu_Post(param1, StringToInt(sInfo));
	}
	else if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
		{
			OpenMapRecordsMenu(param1, gB_OtherMap[param1]);
		}
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void OpenBonusRecordsMenu_Post(int client, int bonus)
{
	Menu menu = new Menu(BonusRecordsMenu_Handler2);

	char sTrack[32];
	GetTrackName(client, bonus, sTrack, sizeof(sTrack));
	menu.SetTitle("记录 %s: [%s] \n(只显示前1000) \n  ", gS_SelectedMap[client], sTrack);

	ArrayList arr = gB_OtherMap[client] ? gA_TempRecordsInfo[client][bonus] : gA_RecordsInfo[bonus];

	for(int j = 0; j < arr.Length; j++)
	{
		recordinfo_t cache;
		arr.GetArray(j, cache, sizeof(recordinfo_t));

		char sTime[32];
		FormatHUDSecondsEx(cache.time, sTime, sizeof(sTime));

		char sDisplay[128];
		FormatEx(sDisplay, sizeof(sDisplay), "#%d - %s - %s (%d 尝试次数)", cache.rank, cache.sName, sTime, cache.completions);
		menu.AddItem("", sDisplay, ITEMDRAW_DISABLED);
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int BonusRecordsMenu_Handler2(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
		{
			OpenBonusRecordsMenu(param1);
		}
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}



/* stage */

void OpenStageRecordsMenu(int client)
{
	Menu menu = new Menu(StageRecordsMenu_Handler);

	menu.SetTitle("请选择关卡: \n(只显示有记录的奖励)\n  ");

	ArrayList arr[STAGES_LIMIT];
	arr = gB_OtherMap[client] ? gA_TempStageRecordsInfo[client] : gA_StageRecordsInfo;

	for(int i = 1; i < STAGES_LIMIT; i++)
	{
		if(arr[i].Length == 0) // this stage has no records found.
		{
			continue;
		}

		char sInfo[4];
		IntToString(i, sInfo, sizeof(sInfo));

		char sStage[16];
		FormatEx(sStage, sizeof(sStage), "关卡 %d", i);

		menu.AddItem(sInfo, sStage);
	}

	if(menu.ItemCount == 0)
	{
		menu.AddItem("", "没有关卡记录, 或许这个图是竞速图? \n(有没有一种可能, SH没有这个地图)", ITEMDRAW_DISABLED);
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int StageRecordsMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[4];
		menu.GetItem(param2, sInfo, sizeof(sInfo));

		OpenStageRecordsMenu_Post(param1, StringToInt(sInfo));
	}
	else if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
		{
			OpenMapRecordsMenu(param1, gB_OtherMap[param1]);
		}
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void OpenStageRecordsMenu_Post(int client, int stage)
{
	Menu menu = new Menu(StageRecordsMenu_Handler2);

	menu.SetTitle("记录 %s: [关卡 %d] \n(只显示前1000) \n  ", gS_SelectedMap[client], stage);

	ArrayList arr = gB_OtherMap[client] ? gA_TempStageRecordsInfo[client][stage] : gA_StageRecordsInfo[stage];

	for(int j = 0; j < arr.Length; j++)
	{
		recordinfo_t cache;
		arr.GetArray(j, cache, sizeof(recordinfo_t));

		char sTime[32];
		FormatHUDSecondsEx(cache.time, sTime, sizeof(sTime));

		char sDisplay[128];
		FormatEx(sDisplay, sizeof(sDisplay), "#%d - %s - %s", cache.rank, cache.sName, sTime);
		menu.AddItem("", sDisplay, ITEMDRAW_DISABLED);
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int StageRecordsMenu_Handler2(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
		{
			OpenStageRecordsMenu(param1);
		}
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}



/* commands */

public Action Command_SurfHeaven_WR(int client, int args)
{
	if(args == 1)
	{
		char sMap[160];
		GetCmdArgString(sMap, sizeof(sMap));

		if(!StrEqual(gS_Map, sMap, false))
		{
			FakeClientCommand(client, "sm_shtop %s", sMap);

			return Plugin_Continue;
		}
	}

	if(gB_CurrentMapFetching)
	{
		Shavit_PrintToChat(client, "当前地图的记录{lightred}仍在获取中{default}, 请耐心等待...");

		return Plugin_Handled;
	}

	if(gA_RecordsInfo[Track_Main].Length == 0)
	{
		Shavit_PrintToChatAll("*{darkred}SurfHeaven{default}* | {lightred}找不到该地图的记录!{default}");

		return Plugin_Handled;
	}

	recordinfo_t cache;
	gA_RecordsInfo[Track_Main].GetArray(0, cache, sizeof(recordinfo_t));

	char sWR[32];
	FormatHUDSecondsEx(cache.time, sWR, sizeof(sWR));

	Shavit_PrintToChatAll("*{darkred}SurfHeaven{default}* | {yellow}当前地图{default} | WR: {green}%s{default}, 保持者: {green}%s{default}, 日期: {green}%s{default}, 尝试次数: {green}%d{default}", 
		sWR, cache.sName, cache.sDate, cache.completions);

	return Plugin_Handled;
}

public Action Command_SurfHeaven_WRCP(int client, int args)
{
	int stage = 1;

	if(args > 0)
	{
		char sArg[8];
		GetCmdArg(1, sArg, sizeof(sArg));
		ReplaceString(sArg, sizeof(sArg), "#", " ");

		stage = StringToInt(sArg);

		if(stage < 1)
		{
			Shavit_PrintToChat(client, "[关卡 %d] 不存在!", stage);

			return Plugin_Handled;
		}
	}

	if(gB_CurrentMapFetching)
	{
		Shavit_PrintToChat(client, "当前地图的关卡记录{lightred}仍在获取中{default}, 请耐心等待...");

		return Plugin_Handled;
	}

	if(gA_StageRecordsInfo[stage].Length == 0)
	{
		Shavit_PrintToChatAll("*{darkred}SurfHeaven{default}* | {lightred}找不到 {gold}[关卡 %d]{lightred} 的记录!{default}", stage);

		return Plugin_Handled;
	}

	recordinfo_t cache;
	gA_StageRecordsInfo[stage].GetArray(0, cache, sizeof(recordinfo_t));

	char sWR[32];
	FormatHUDSecondsEx(cache.time, sWR, sizeof(sWR));

	Shavit_PrintToChatAll("*{darkred}SurfHeaven{default}* | {yellow}当前地图{default} | {gold}[关卡 %d]{default} WRCP: {green}%s{default}, 保持者: {green}%s{default}, 日期: {green}%s{default}", 
		stage, sWR, cache.sName, cache.sDate);

	return Plugin_Handled;
}



// ======[ STOCKS ]======

stock void FormatURL(char[] output, int maxlen, const char[] api, const char[] param)
{
	FormatEx(output, maxlen, "%s%s", api, param);
}

stock void SortRecords(ArrayList[] arr, int len)
{
	for(int i = 0; i < len; i++)
	{
		arr[i].SortCustom(SortRecordByTimeASC);

		if(arr[i].Length > MAX_RECORDS)
		{
			arr[i].Resize(MAX_RECORDS);
		}
	}
}

static int SortRecordByTimeASC(int index1, int index2, Handle array, Handle hndl)
{
	ArrayList arr = view_as<ArrayList>(array);
	recordinfo_t cache1, cache2;
	arr.GetArray(index1, cache1, sizeof(recordinfo_t));
	arr.GetArray(index2, cache2, sizeof(recordinfo_t));

	return cache1.time > cache2.time; /* ASC(default) if true, DESC if false(<=0?)*/
}

static void InitTempRecords(int client)
{
	for(int i = 0; i < TRACK_LIMIT; i++)
	{
		delete gA_TempRecordsInfo[client][i];
		gA_TempRecordsInfo[client][i] = new ArrayList(sizeof(recordinfo_t));
	}

	for(int i = 0; i < STAGES_LIMIT; i++)
	{
		delete gA_TempStageRecordsInfo[client][i];
		gA_TempStageRecordsInfo[client][i] = new ArrayList(sizeof(recordinfo_t));
	}
}

static void FormatHUDSecondsEx(float time, char[] newtime, int newtimesize)
{
	float fTempTime = time;

	if(fTempTime < 0.0)
	{
		fTempTime = -fTempTime;
	}
	
	int iRounded = RoundToFloor(fTempTime);
	float fSeconds = (iRounded % 60) + fTempTime - iRounded;

	char sSeconds[8];
	FormatEx(sSeconds, 8, "%.03f", fSeconds);

	if(fTempTime < 60.0)
	{
		strcopy(newtime, newtimesize, sSeconds);
		FormatEx(newtime, newtimesize, "%s00:%s%s", (time < 0.0) ? "-":"", (fSeconds < 10) ? "0":"", sSeconds);
	}

	else
	{
		int iMinutes = (iRounded / 60);

		if(fTempTime < 3600.0)
		{
			FormatEx(newtime, newtimesize, "%s%s%d:%s%s", (time < 0.0)? "-":"", (fTempTime < 600)? "0":"", iMinutes, (fSeconds < 10)? "0":"", sSeconds);
		}

		else
		{
			iMinutes %= 60;
			int iHours = (iRounded / 3600);

			FormatEx(newtime, newtimesize, "%s%d:%s%d:%s%s", (time < 0.0)? "-":"", iHours, (iMinutes < 10)? "0":"", iMinutes, (fSeconds < 10)? "0":"", sSeconds);
		}
	}
}

static void WriteRecordsToCache(JSONObject json, recordinfo_t cache, int& track)
{
	json.GetString("name", cache.sName, sizeof(recordinfo_t::sName));

	float time = json.GetFloat("time");
	if(time == 0.0) /* SH在比如57.000这种时间, 只存储57, 不保留小数, 你妈的, json还读取出错, 离谱 */
	{
		time = float(json.GetInt("time"));
	}

	cache.time = time;

	cache.rank = json.GetInt("rank");

	track = json.GetInt("track");

	char sDate[128];
	json.GetString("date", sDate, sizeof(sDate));
	//"2021-04-09T14:40:51.000Z",
	sDate[FindCharInString(sDate, 'T')] = ' ';
	sDate[FindCharInString(sDate, '.', true)] = '\0';

	strcopy(cache.sDate, sizeof(recordinfo_t::sDate), sDate);

	cache.completions = json.GetInt("finishcount");
}

static void WriteWRCPsToCache(JSONObject json, recordinfo_t cache, int& stage)
{
	json.GetString("name", cache.sName, sizeof(recordinfo_t::sName));

	float time = json.GetFloat("time");
	if(time == 0.0) /* SH在比如57.000这种时间, 只存储57, 不保留小数, 你妈的, json还读取出错, 离谱 */
	{
		time = float(json.GetInt("time"));
	}

	cache.time = time;

	cache.rank = json.GetInt("rank");

	stage = json.GetInt("stage");

	char sDate[128];
	json.GetString("date", sDate, sizeof(sDate));
	//"2021-04-09T14:40:51.000Z",
	sDate[FindCharInString(sDate, 'T')] = ' ';
	sDate[FindCharInString(sDate, '.', true)] = '\0';

	strcopy(cache.sDate, sizeof(recordinfo_t::sDate), sDate);
}