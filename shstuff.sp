#include <sourcemod>
#include <ripext>
#include <shavit>

#define HEAVEN_MAPINFO_API "https://surfheaven.eu/api/mapinfo/"
#define HEAVEN_RECORDS_API "https://surfheaven.eu/api/records/"

#define MAX_RECORDS 1000

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

// other map record
ArrayList gA_TempRecordsInfo[MAXPLAYERS+1][TRACK_LIMIT];
bool gB_OtherMap[MAXPLAYERS+1];
Handle gH_FetchTimer[MAXPLAYERS+1];



public void OnPluginStart()
{
	LoadTranslations("shavit-common.phrases");

	RegConsoleCmd("sm_shm", Command_SurfHeaven_Mapinfo);
	RegConsoleCmd("sm_shtop", Command_SurfHeaven_Top);
	RegConsoleCmd("sm_shwr", Command_SurfHeaven_WR);
}

public void OnMapStart()
{
	GetCurrentMap(gS_Map, sizeof(gS_Map));

	for(int i = 0; i < TRACK_LIMIT; i++)
	{
		delete gA_RecordsInfo[i];
		gA_RecordsInfo[i] = new ArrayList(sizeof(recordinfo_t));
	}

	SurfHeaven_GetCurrentMapRecords();
}

void SurfHeaven_GetCurrentMapRecords()
{
	char sURL[512];
	FormatURL(sURL, sizeof(sURL), HEAVEN_RECORDS_API, gS_Map);
	HTTPRequest records = new HTTPRequest(sURL);
	records.Get(GetCurrentMapRecords_Callback);
}

public void GetCurrentMapRecords_Callback(HTTPResponse response, any value, const char[] error)
{
	if(response.Status != HTTPStatus_OK)
	{
		LogError("*SurfHeaven* 获取地图信息失败! 原因: %s", error);
		return;
	}

	response.Data.ToFile("currecords.json");

	JSONArray records = JSONArray.FromFile("currecords.json");

	for(int i = 0; i < records.Length; i++)
	{
		JSONObject info = view_as<JSONObject>(records.Get(i));

		recordinfo_t cache;

		info.GetString("name", cache.sName, sizeof(recordinfo_t::sName));

		float time = info.GetFloat("time");
		if(time == 0.0) /* SH在比如57.000这种时间, 只存储57, 不保留小数, 你妈的, json还读取出错, 离谱 */
		{
			time = float(info.GetInt("time"));
		}

		cache.time = time;

		cache.rank = info.GetInt("rank");

		int track = info.GetInt("track");

		char sDate[128];
		info.GetString("date", sDate, sizeof(sDate));
		//"2021-04-09T14:40:51.000Z",
		sDate[FindCharInString(sDate, 'T')] = ' ';
		sDate[FindCharInString(sDate, '.', true)] = '\0';

		strcopy(cache.sDate, sizeof(recordinfo_t::sDate), sDate);

		cache.completions = info.GetInt("finishcount");

		gA_RecordsInfo[track].PushArray(cache);

		delete info;
	}

	delete records;

	SortRecords(gA_RecordsInfo);

	Shavit_PrintToChatAll("*{darkred}SurfHeaven{default}* 输入{green}!shm{default}, {green}!shwr{default}, {green}!shtop{default}以获取地图信息和记录");
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
		strcopy(gS_SelectedMap[client], sizeof(gS_SelectedMap[]), gS_Map);
		OpenMapRecordsMenu(client, false);

		return Plugin_Handled;
	}

	GetCmdArgString(gS_SelectedMap[client], sizeof(gS_SelectedMap[]));
	GetOtherMapRecords(client, gS_SelectedMap[client]);

	Shavit_PrintToChat(client, "查询{lightgreen}其他地图{default}记录时会有{darkred}延迟{default}, 请稍后...");

	gH_FetchTimer[client] = CreateTimer(30.0, Timer_FetchFailTips, GetClientSerial(client));

	return Plugin_Handled;
}

public Action Timer_FetchFailTips(Handle timer, any data)
{
	int client = GetClientFromSerial(data);

	Shavit_PrintToChat(client, "{lightred}30秒钟{default}过去了, "...
		"如果{darkred}还没有{default}查出来结果, "...
		"请亲自去官网查询: {green}https://surfheaven.eu/map/%s{default}", 
		gS_SelectedMap[client]);

	gH_FetchTimer[client] = null;

	return Plugin_Stop;
}

void GetOtherMapRecords(int client, const char[] map)
{
	char sURL[512];
	FormatURL(sURL, sizeof(sURL), HEAVEN_RECORDS_API, map);
	HTTPRequest records = new HTTPRequest(sURL);
	records.Get(GetOtherMapRecords_Callback, GetClientSerial(client));
}

public void GetOtherMapRecords_Callback(HTTPResponse response, any value, const char[] error)
{
	int client = GetClientFromSerial(value);

	if(response.Status != HTTPStatus_OK)
	{
		Shavit_PrintToChat(client, "*{darkred}SurfHeaven{default}* 获取地图信息失败! 原因: %s", error);
		return;
	}

	response.Data.ToFile("otherrecords.json");

	delete gH_FetchTimer[client];
	Shavit_PrintToChat(client, "*{darkred}SurfHeaven{default}* 记录信息获取成功");

	JSONArray records = JSONArray.FromFile("otherrecords.json");

	InitTempRecords(client);

	for(int i = 0; i < records.Length; i++)
	{
		JSONObject info = view_as<JSONObject>(records.Get(i));

		recordinfo_t cache;

		info.GetString("name", cache.sName, sizeof(recordinfo_t::sName));

		float time = info.GetFloat("time");
		if(time == 0.0) /* SH在比如57.000这种时间, 只存储57, 不保留小数, 你妈的, json还读取出错, 离谱 */
		{
			time = float(info.GetInt("time"));
		}

		cache.time = time;

		cache.rank = info.GetInt("rank");

		int track = info.GetInt("track");

		char sDate[128];
		info.GetString("date", sDate, sizeof(sDate));
		//"2021-04-09T14:40:51.000Z",
		sDate[FindCharInString(sDate, 'T')] = ' ';
		sDate[FindCharInString(sDate, '.', true)] = '\0';

		strcopy(cache.sDate, sizeof(recordinfo_t::sDate), sDate);

		cache.completions = info.GetInt("finishcount");

		gA_TempRecordsInfo[client][track].PushArray(cache);

		delete info;
	}

	delete records;

	SortRecords(gA_TempRecordsInfo[client]);

	OpenMapRecordsMenu(client, true);
}

void OpenMapRecordsMenu(int client, bool othermap)
{
	gB_OtherMap[client] = othermap;

	Menu menu = new Menu(MapRecordsMenu_Handler);

	menu.SetTitle("SH记录查询: %s\n  ", gS_SelectedMap[client]);

	menu.AddItem("main", "主线记录");
	menu.AddItem("bonus", "奖励关记录");

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
		else
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

void OpenMainRecordsMenu(int client)
{
	Menu menu = new Menu(MainRecordsMenu_Handler);

	menu.SetTitle("记录 %s: [主线] \n(只显示前1000)\n  ", gS_SelectedMap[client]);

	ArrayList arr = gB_OtherMap[client] ? gA_TempRecordsInfo[client][Track_Main] : gA_RecordsInfo[Track_Main];

	for(int i = 0; i < arr.Length; i++)
	{
		recordinfo_t cache;
		arr.GetArray(i, cache, sizeof(recordinfo_t));

		char sDisplay[128]
		FormatEx(sDisplay, sizeof(sDisplay), "#%d - %s - %.3f (%d 尝试次数)", cache.rank, cache.sName, cache.time, cache.completions);
		menu.AddItem("", sDisplay, ITEMDRAW_DISABLED);
	}

	if(menu.ItemCount == 0)
	{
		menu.AddItem("", "惊了, SH无记录...", ITEMDRAW_DISABLED);
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
		menu.AddItem("", "没有奖励关记录, 或许这个图压根就没有奖励关?", ITEMDRAW_DISABLED);
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

		char sDisplay[128];
		FormatEx(sDisplay, sizeof(sDisplay), "#%d - %s - %.3f (%d 尝试次数)", cache.rank, cache.sName, cache.time, cache.completions);
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

	if(gA_RecordsInfo[Track_Main].Length == 0)
	{
		Shavit_PrintToChatAll("*{darkred}SurfHeaven{default}* | {lightred}找不到该地图的记录!{default}");

		return Plugin_Handled;
	}

	recordinfo_t cache;
	gA_RecordsInfo[Track_Main].GetArray(0, cache, sizeof(recordinfo_t));

	char sWR[32];
	FormatHUDSeconds(cache.time, sWR, sizeof(sWR));

	Shavit_PrintToChatAll("*{darkred}SurfHeaven{default}* | {lightred}当前地图{default} WR: {green}%s{default}, 保持者: {green}%s{default}, 日期: {green}%s{default}, 尝试次数: {green}%d{default}", 
		sWR, cache.sName, cache.sDate, cache.completions);

	return Plugin_Handled;
}



// ======[ STOCKS ]======

stock void FormatURL(char[] output, int maxlen, const char[] api, const char[] param)
{
	FormatEx(output, maxlen, "%s%s", api, param);
}

stock void SortRecords(ArrayList[] arr)
{
	for(int i = 0; i < TRACK_LIMIT; i++)
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
}
