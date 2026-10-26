# 路局语音播报：根据列车归属路局生成特色播报词，用系统 TTS 朗读。
# 播报词基于真实车次数据（车次号、始发终到、下一站），路局决定文风模板。
extends RefCounted

# 路局编号 -> (名称, 播报风格前缀, 语音偏好)
const BUREAUS := {
	"shanghai": {"name": "中国铁路上海局集团", "prefix": "各位旅客请注意"},
	"beijing":  {"name": "中国铁路北京局集团", "prefix": "旅客朋友们请注意"},
	"guangzhou":{"name": "中国铁路广州局集团", "prefix": "各位旅客，"},
	"chengdu":  {"name": "中国铁路成都局集团", "prefix": "旅客朋友们"},
	"xianggang":{"name": "中国铁路广州局集团", "prefix": "各位旅客，"},
	"nanning":  {"name": "中国铁路南宁局集团", "prefix": "各位旅客请注意"},
	"nanjing":  {"name": "中国铁路上海局集团", "prefix": "各位旅客请注意"},
	"jinan":    {"name": "中国铁路济南局集团", "prefix": "旅客朋友们请注意"},
	"zhengzhou":{"name": "中国铁路郑州局集团", "prefix": "各位旅客请注意"},
	"wuhan":    {"name": "中国铁路武汉局集团", "prefix": "旅客朋友们请注意"},
	"xian":     {"name": "中国铁路西安局集团", "prefix": "各位旅客请注意"},
	"shenyang": {"name": "中国铁路沈阳局集团", "prefix": "旅客朋友们请注意"},
	"harbin":   {"name": "中国铁路哈尔滨局集团", "prefix": "旅客朋友们请注意"},
	"lanzhou":  {"name": "中国铁路兰州局集团", "prefix": "各位旅客请注意"},
	"urumqi":   {"name": "中国铁路乌鲁木齐局集团", "prefix": "各位旅客请注意"},
	"kunming":  {"name": "中国铁路昆明局集团", "prefix": "各位旅客请注意"},
	"taiyuan":  {"name": "中国铁路太原局集团", "prefix": "旅客朋友们请注意"},
	"hohhot":   {"name": "中国铁路呼和浩特局集团", "prefix": "各位旅客请注意"},
	"nanchang": {"name": "中国铁路南昌局集团", "prefix": "各位旅客请注意"},
	"qingzang": {"name": "中国铁路青藏集团", "prefix": "各位旅客请注意"},
}

# 根据车站名推断归属路局（按地理区域粗略匹配）
static func bureau_from_station(sname: String) -> String:
	var city := sname
	for suffix in ["东", "南", "西", "北"]:
		if sname.ends_with(suffix):
			city = sname.trim_suffix(suffix)
			break
	var region := {
		"北京": "beijing", "廊坊": "beijing", "保定": "beijing", "涿州": "beijing",
		"天津": "beijing", "唐山": "beijing", "秦皇岛": "beijing", "承德": "beijing",
		"张家口": "beijing", "廊坊北": "beijing",
		"上海": "shanghai", "苏州": "shanghai", "无锡": "shanghai", "常州": "shanghai",
		"南京": "shanghai", "镇江": "shanghai", "合肥": "shanghai", "芜湖": "shanghai",
		"杭州": "shanghai", "宁波": "shanghai", "温州": "shanghai", "嘉兴": "shanghai",
		"金华": "shanghai", "衢州": "shanghai", "淮安": "shanghai", "盐城": "shanghai",
		"南通": "shanghai", "扬州": "shanghai", "绍兴": "shanghai", "义乌": "shanghai",
		"济南": "jinan", "淄博": "jinan", "潍坊": "jinan", "青岛": "jinan", "日照": "jinan",
		"烟台": "jinan", "临沂": "jinan", "聊城": "jinan", "德州": "jinan",
		"郑州": "zhengzhou", "洛阳": "zhengzhou", "开封": "zhengzhou", "新乡": "zhengzhou",
		"安阳": "zhengzhou", "商丘": "zhengzhou", "许昌": "zhengzhou", "南阳": "zhengzhou",
		"武汉": "wuhan", "宜昌": "wuhan", "襄阳": "wuhan", "孝感": "wuhan", "十堰": "wuhan",
		"长沙": "wuhan", "岳阳": "wuhan", "常德": "wuhan", "益阳": "wuhan",
		"广州": "guangzhou", "深圳": "guangzhou", "珠海": "guangzhou", "佛山": "guangzhou",
		"东莞": "guangzhou", "惠州": "guangzhou", "中山": "guangzhou", "汕头": "guangzhou",
		"潮州": "guangzhou", "揭阳": "guangzhou", "汕尾": "guangzhou", "清远": "guangzhou",
		"韶关": "guangzhou", "香港": "xianggang",
		"西安": "xian", "宝鸡": "xian", "咸阳": "xian", "渭南": "xian", "汉中": "xian",
		"安康": "xian", "延安": "xian", "榆林": "xian", "商洛": "xian", "铜川": "xian",
		"成都": "chengdu", "绵阳": "chengdu", "德阳": "chengdu", "乐山": "chengdu",
		"宜宾": "chengdu", "重庆": "chengdu", "南充": "chengdu", "达州": "chengdu",
		"内江": "chengdu", "自贡": "chengdu", "泸州": "chengdu", "遂宁": "chengdu",
		"贵阳": "chengdu", "遵义": "chengdu", "安顺": "chengdu", "毕节": "chengdu",
		"昆明": "kunming", "曲靖": "kunming", "玉溪": "kunming", "大理": "kunming",
		"丽江": "kunming", "保山": "kunming", "普洱": "kunming", "景洪": "kunming",
		"南昌": "nanchang", "九江": "nanchang", "赣州": "nanchang", "上饶": "nanchang",
		"宜春": "nanchang", "抚州": "nanchang", "吉安": "nanchang", "景德镇": "nanchang",
		"福州": "nanchang", "厦门": "nanchang", "泉州": "nanchang", "莆田": "nanchang",
		"漳州": "nanchang", "龙岩": "nanchang", "南平": "nanchang", "宁德": "nanchang",
		"太原": "taiyuan", "晋中": "taiyuan", "运城": "taiyuan", "临汾": "taiyuan",
		"长治": "taiyuan", "晋城": "taiyuan", "大同": "taiyuan", "朔州": "taiyuan",
		"南宁": "nanning", "柳州": "nanning", "桂林": "nanning", "北海": "nanning",
		"贵港": "nanning", "玉林": "nanning", "梧州": "nanning", "百色": "nanning",
		"兰州": "lanzhou", "天水": "lanzhou", "定西": "lanzhou", "陇南": "lanzhou",
		"银川": "lanzhou", "吴忠": "lanzhou", "中卫": "lanzhou", "固原": "lanzhou",
		"西宁": "qingzang", "格尔木": "qingzang", "德令哈": "qingzang", "拉萨": "qingzang",
		"那曲": "qingzang", "日喀则": "qingzang", "林芝": "qingzang",
		"乌鲁木齐": "urumqi", "吐鲁番": "urumqi", "哈密": "urumqi", "库尔勒": "urumqi",
		"喀什": "urumqi", "阿克苏": "urumqi", "伊宁": "urumqi", "和田": "urumqi",
		"克拉玛依": "urumqi", "奎屯": "urumqi", "石河子": "urumqi",
		"沈阳": "shenyang", "大连": "shenyang", "鞍山": "shenyang", "抚顺": "shenyang",
		"本溪": "shenyang", "丹东": "shenyang", "锦州": "shenyang", "营口": "shenyang",
		"朝阳": "shenyang", "盘锦": "shenyang", "铁岭": "shenyang", "葫芦岛": "shenyang",
		"长春": "shenyang", "吉林": "shenyang", "四平": "shenyang", "通化": "shenyang",
		"白城": "shenyang", "延吉": "shenyang", "松原": "shenyang", "辽源": "shenyang",
		"哈尔滨": "harbin", "齐齐哈尔": "harbin", "大庆": "harbin", "牡丹江": "harbin",
		"佳木斯": "harbin", "鸡西": "harbin", "鹤岗": "harbin", "双鸭山": "harbin",
		"伊春": "harbin", "七台河": "harbin, ", "黑河": "harbin", "绥化": "harbin",
		"呼和浩特": "hohhot", "包头": "hohhot", "乌兰察布": "hohhot", "鄂尔多斯": "hohhot",
		"赤峰": "hohhot", "通辽": "hohhot", "呼伦贝尔": "hohhot", "巴彦淖尔": "hohhot",
	}
	for city_name in region:
		if city.begins_with(city_name) or sname.begins_with(city_name):
			return region[city_name]
	return "shanghai"


static func bureau_name(bureau_id: String) -> String:
	return BUREAUS.get(bureau_id, BUREAUS["shanghai"])["name"]


# 生成进站播报词（真实车次数据 + 路局风格）
static func arrival_text(bureau_id: String, code: String, from: String,
		to: String, next_station: String) -> String:
	var b: Dictionary = BUREAUS.get(bureau_id, BUREAUS["shanghai"])
	var prefix: String = b["prefix"]
	if code.begins_with("G"):
		return "%s，由%s开往%s方向的%s次列车即将进站，请乘坐本次列车的旅客朋友到站台候车，上车后请按票面信息对号入座。" % [
			prefix, from, to, code]
	elif code.begins_with("D"):
		return "%s，由%s开往%s方向的%s次列车即将进站，请乘坐本次列车的旅客朋友提前到站台候车。" % [
			prefix, from, to, code]
	return "%s，由%s开往%s方向的%s次列车马上就要进站了，请旅客朋友们提前做好准备。" % [
		prefix, from, to, code]


# 生成车内报站词（下一站）
static func onboard_text(code: String, next_station: String) -> String:
	return "各位旅客，本次列车前方到站是%s站，请在%s站下车的旅客朋友提前做好准备。" % [
		next_station, next_station]


# 生成发车播报词
static func departure_text(code: String, from: String, to: String) -> String:
	return "%s，由%s开往%s方向的%s次列车马上就要发车了，请旅客朋友尽快上车。" % [
		BUREAUS.get(bureau_id_from_station(from), BUREAUS["shanghai"])["prefix"],
		from, to, code]


static func bureau_id_from_station(sname: String) -> String:
	return bureau_from_station(sname)
