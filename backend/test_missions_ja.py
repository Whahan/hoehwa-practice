# -*- coding: utf-8 -*-
"""Independent sentence test for the Japanese mission rules (design v1.7.0 sec 2.3, task B2t).

The sentences below were written by a different worker than the rule author, from the mission list only (id, scene,
goal label_ko / goal_en) BEFORE the rules (match / pos / neg) were looked at. They are fixed: do not edit, drop or add
sentences after a measurement. Rule failures are fixed in the content (task B2), not here.

For every goal: POS sentences should reach the goal (miss = "under", a correct sentence is not accepted),
NEG sentences should not reach it (hit = "over", a wrong sentence is accepted). Each sentence is checked with the real
server function missions.check_text("ja", mission_id, text) on the mission's own goals (no network, no AI).

Usage (from the repository root):
  backend\\.venv\\Scripts\\python.exe -I backend\\test_missions_ja.py [--content PATH_TO_missions.json] [--no-selfcheck] [--quiet]
Exit code 0 only if: every goal of every ja_ mission is covered, total under <= 15%, per-goal under <= 30%, total over <= 10%,
no sentence raised an error, the sentence data hash is unchanged, and the self-checks (broken content must FAIL) behave.
"""
import os
import sys
import json
import shutil
import hashlib
import tempfile

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)          # python -I does not put the script folder on sys.path
import missions as M              # light: no models, no network

DEFAULT_CONTENT = os.path.join(HERE, "content", "missions.json")
MAX_UNDER_TOTAL = 0.15
MAX_UNDER_GOAL = 0.30
MAX_OVER_TOTAL = 0.10
MIN_POS, MIN_NEG = 8, 6


SENTENCES = {
 "ja_konbini": {
  "find_item": {
   "pos": [
    "すみません、お茶はどこにありますか。",
    "おにぎりはどこですか？",
    "牛乳どこですか",
    "電池はありますか。",
    "みずはどこにおいてありますか",
    "パンの売り場はどこですか。",
    "ボールペンはありますか？",
    "アイスクリームはどこにありますか",
    "すみません、マスクを探しているんですが。",
    "コーヒーはどこですか。",
    "お弁当ってどこにありますか",
    "ビールはどこにありますかね。"
   ],
   "neg": [
    "このお弁当をください。",
    "温めてください。",
    "カードで払います。",
    "ありがとうございました。",
    "袋はいりません。",
    "おはようございます。",
    "今日は暑いですね。",
    "いくらですか。",
    "現金でお願いします。"
   ]
  },
  "buy_item": {
   "pos": [
    "これをください。",
    "これください",
    "この水をお願いします。",
    "おにぎり二つください。",
    "コーヒーを一つお願いします。",
    "肉まんを一つください。",
    "サンドイッチを買いたいです。",
    "このお弁当をください。",
    "あのパンをお願いします",
    "からあげを二つください",
    "これを買います。",
    "ビールを一本ください。"
   ],
   "neg": [
    "お茶はどこにありますか。",
    "カードで払います。",
    "温めてください。",
    "ありがとうございます。",
    "袋はいりません。",
    "今日は寒いですね。",
    "いくらですか。",
    "はい、そうです。",
    "こんにちは。"
   ]
  },
  "heat_bag": {
   "pos": [
    "温めてください。",
    "あたためてもらえますか。",
    "袋はいりません。",
    "袋をお願いします。",
    "お箸をください。",
    "レジ袋は大丈夫です。",
    "はい、温めてください。",
    "温めなくていいです。",
    "袋に入れてもらえますか。",
    "おはしはいりません。",
    "そのままで大丈夫です。",
    "割り箸もください。"
   ],
   "neg": [
    "お茶はどこですか。",
    "これをください。",
    "カードで払います。",
    "ありがとうございました。",
    "いくらですか。",
    "おにぎりを二つください。",
    "現金でお願いします。",
    "今日は暑いですね。"
   ]
  },
  "pay": {
   "pos": [
    "カードで払います。",
    "現金でお願いします。",
    "クレジットカードでお願いします。",
    "Suicaで払えますか。",
    "PayPayは使えますか。",
    "げんきんでおねがいします。",
    "カードでお願いします。",
    "電子マネーでお願いします。",
    "交通系ICカードで払います。",
    "スマホで払ってもいいですか。",
    "現金で払います。",
    "カードは使えますか。"
   ],
   "neg": [
    "お弁当を温めてください。",
    "これをください。",
    "袋はいりません。",
    "ありがとうございました。",
    "お水はどこにありますか。",
    "いくらですか。",
    "レシートをお願いします。",
    "今日はいい天気ですね。"
   ]
  },
  "thank": {
   "pos": [
    "ありがとうございます。",
    "ありがとうございました。",
    "どうもありがとう。",
    "ありがとう！",
    "どうもありがとうございました。",
    "助かりました、ありがとうございます。",
    "ありがとうございました、また来ます。",
    "ありがとうございます、お世話になりました。",
    "ありがとうございました。さようなら。",
    "どうもありがとうございます。",
    "ありがとね。",
    "アリガトウゴザイマス。",
    "有難うございます。"
   ],
   "neg": [
    "これをください。",
    "カードで払います。",
    "お弁当を温めてください。",
    "お茶はどこですか。",
    "袋はいりません。",
    "いくらですか。",
    "こんにちは。",
    "はい、お願いします。",
    "ごめんなさい。"
   ]
  }
 },
 "ja_ramen": {
  "seat_party": {
   "pos": [
    "二人です。",
    "ふたりです。",
    "三人です。",
    "一人です。",
    "カウンターでお願いします。",
    "テーブル席がいいです。",
    "四人です、テーブルでお願いします。",
    "2名です。",
    "大人二人です。",
    "カウンター席でもいいですか。",
    "ひとりですが、大丈夫ですか。",
    "3人です"
   ],
   "neg": [
    "ラーメンをください。",
    "醤油ラーメンをお願いします。",
    "お会計をお願いします。",
    "ごちそうさまでした。",
    "麺は硬めでお願いします。",
    "水をください。",
    "お腹がすきました。",
    "トイレはどこですか。",
    "おいしそうですね。"
   ]
  },
  "order_ramen": {
   "pos": [
    "醤油ラーメンをください。",
    "ラーメンをお願いします。",
    "とんこつラーメンをください。",
    "みそラーメンひとつお願いします。",
    "らーめんください。",
    "おすすめのラーメンをお願いします。",
    "塩ラーメンにします。",
    "チャーシュー麺をください。",
    "つけ麺をお願いします。",
    "ラーメンと餃子をお願いします。",
    "とんこつラーメンを一つお願いします。",
    "味噌ラーメンを食べたいです。"
   ],
   "neg": [
    "二人です。",
    "カウンターでお願いします。",
    "お会計をお願いします。",
    "ごちそうさまでした。",
    "辛さは普通でお願いします。",
    "お水をください。",
    "トイレはどこですか。",
    "ありがとうございます。",
    "おすすめは何ですか。"
   ]
  },
  "customize": {
   "pos": [
    "麺は硬めでお願いします。",
    "かためでおねがいします。",
    "大盛りにしてください。",
    "辛さは普通でお願いします。",
    "ネギ多めでお願いします。",
    "麺少なめでお願いします。",
    "ねぎ抜きでお願いします。",
    "味は濃いめでお願いします。",
    "麺を柔らかめにしてください。",
    "チャーシューを増やしてもいいですか。",
    "辛くしてください。",
    "煮卵をトッピングしてください。"
   ],
   "neg": [
    "二人です。",
    "醤油ラーメンをください。",
    "お会計をお願いします。",
    "ごちそうさまでした。",
    "カウンターでお願いします。",
    "水をください。",
    "トイレはどこですか。",
    "今日は寒いですね。",
    "とんこつラーメンをお願いします。"
   ]
  },
  "ask_bill": {
   "pos": [
    "お会計をお願いします。",
    "おかいけいおねがいします。",
    "お勘定お願いします。",
    "会計お願いします。",
    "カードで払えますか。",
    "支払いをお願いします。",
    "お会計、別々でお願いします。",
    "お会計をしてもらえますか。",
    "そろそろ会計をお願いします。",
    "おあいそお願いします。",
    "お愛想お願いします。"
   ],
   "neg": [
    "二人です。",
    "醤油ラーメンをください。",
    "麺は硬めでお願いします。",
    "ごちそうさまでした。",
    "水をください。",
    "カウンターでお願いします。",
    "トイレはどこですか。",
    "おいしかったです。",
    "ラーメンをもう一つお願いします。"
   ]
  },
  "thank": {
   "pos": [
    "ごちそうさまでした。",
    "ごちそうさま。",
    "ご馳走様でした。",
    "ごちそうさまでした、おいしかったです。",
    "ありがとうございました。",
    "とてもおいしかったです。",
    "おいしかったです、ごちそうさま。",
    "ありがとうございます。また来ます。",
    "ごちそうさまです。",
    "美味しかったです。ありがとうございました。",
    "ゴチソウサマデシタ。",
    "どうもありがとうございました。"
   ],
   "neg": [
    "二人です。",
    "醤油ラーメンをください。",
    "麺は硬めでお願いします。",
    "お会計をお願いします。",
    "水をください。",
    "トイレはどこですか。",
    "カウンターでお願いします。",
    "ちょっと辛すぎました。"
   ]
  }
 },
 "ja_ask_way": {
  "call_out": {
   "pos": [
    "すみません。",
    "すみません、ちょっといいですか。",
    "あの、すみません。",
    "すみません、ちょっとお尋ねしたいんですが。",
    "すみません、お聞きしてもいいですか。",
    "ちょっと失礼します、いいですか。",
    "すいません。",
    "あのう、すみません、道を教えてください。",
    "すみません、少しいいですか。",
    "こんにちは、すみません。",
    "すみません、ちょっとよろしいですか。",
    "すみませーん。"
   ],
   "neg": [
    "駅はどこですか。",
    "ありがとうございました。",
    "ここからどのくらいかかりますか。",
    "もう一度お願いします。",
    "さようなら。",
    "まっすぐ行きますか。",
    "今日は暑いですね。",
    "銀行に行きたいです。",
    "あのう、少しお時間ありますか。",
    "本当に助かりました。"
   ]
  },
  "ask_place": {
   "pos": [
    "駅はどこですか。",
    "駅どこですか。",
    "銀行はどこにありますか。",
    "郵便局への行き方を教えてください。",
    "東京タワーに行きたいんですが。",
    "このホテルはどこですか。",
    "コンビニはどこにありますか。",
    "浅草寺までどうやって行きますか。",
    "トイレはどこでしょうか。",
    "道を教えてもらえますか。",
    "空港へはどう行けばいいですか。",
    "えきはどこですか。",
    "バスていはどこですか。"
   ],
   "neg": [
    "すみません。",
    "ここから遠いですか。",
    "どのくらいかかりますか。",
    "ありがとうございました。",
    "もう一度言ってください。",
    "まっすぐですね。",
    "いい天気ですね。",
    "さようなら。",
    "私は学生です。"
   ]
  },
  "ask_distance": {
   "pos": [
    "ここから遠いですか。",
    "駅まで歩いてどのくらいかかりますか。",
    "どのくらいかかりますか。",
    "近いですか。",
    "歩いて何分ですか。",
    "ここから何キロありますか。",
    "バスで何分ぐらいですか。",
    "遠いですか？",
    "どれくらいかかりますか。",
    "歩いて十分くらいですか。",
    "駅までどのくらいの距離ですか。",
    "ちかいですか。"
   ],
   "neg": [
    "駅はどこですか。",
    "すみません。",
    "ありがとうございました。",
    "もう一度言ってください。",
    "まっすぐ行って右ですね。",
    "銀行に行きたいです。",
    "いい天気ですね。",
    "さようなら。",
    "道に迷いました。"
   ]
  },
  "confirm_route": {
   "pos": [
    "まっすぐ行って、右ですね。",
    "もう一度お願いします。",
    "もう一度言ってください。",
    "ゆっくり話してもらえますか。",
    "信号を左ですね。",
    "すみません、もう少しゆっくりお願いします。",
    "次の角を曲がるんですよね。",
    "つまり、まっすぐ行って左ですか。",
    "もう一回言ってもらえますか。",
    "右に曲がるんですね。",
    "わかりません、もう一度教えてください。",
    "ゆっくりおねがいします。"
   ],
   "neg": [
    "駅はどこですか。",
    "すみません。",
    "ここから遠いですか。",
    "ありがとうございました。",
    "さようなら。",
    "銀行に行きたいです。",
    "歩いて何分ですか。",
    "いい天気ですね。",
    "おなかがすきました。"
   ]
  },
  "thank_bye": {
   "pos": [
    "ありがとうございました。",
    "ありがとうございます、助かりました。",
    "どうもありがとう。さようなら。",
    "ありがとうございました。失礼します。",
    "助かりました。ありがとうございます。",
    "ありがとう。じゃあ、また。",
    "親切にありがとうございます。",
    "さようなら。ありがとうございました。",
    "どうもありがとうございました。",
    "ありがとう！",
    "では、失礼します。ありがとうございました。",
    "ありがとうございました、気をつけて帰ります。"
   ],
   "neg": [
    "駅はどこですか。",
    "すみません。",
    "ここから遠いですか。",
    "もう一度言ってください。",
    "右ですね。",
    "銀行に行きたいです。",
    "おなかがすきました。",
    "歩いて何分ですか。",
    "迷子になりました。"
   ]
  }
 },
 "ja_hotel_checkin": {
  "reservation": {
   "pos": [
    "予約している田中です。",
    "予約をしていた山田です。",
    "チェックインをお願いします。",
    "チェックインしたいんですが。",
    "予約したキムです。",
    "よやくしているすずきです。",
    "田中で予約しています。",
    "今日から二泊で予約しています。",
    "チェックインできますか。",
    "ネットで予約しました。",
    "予約があるんですが。",
    "チェックインおねがいします。"
   ],
   "neg": [
    "禁煙の部屋をお願いします。",
    "朝食は何時からですか。",
    "チェックアウトは何時ですか。",
    "荷物を預かってもらえますか。",
    "Wi-Fiのパスワードを教えてください。",
    "ありがとうございます。",
    "トイレはどこですか。",
    "今日は暑いですね。",
    "高い階がいいです。"
   ]
  },
  "room_request": {
   "pos": [
    "禁煙の部屋をお願いします。",
    "高い階の部屋がいいです。",
    "静かな部屋にしてください。",
    "ツインの部屋はありますか。",
    "海が見える部屋をお願いします。",
    "部屋を変えてもらえますか。",
    "きんえんのへやがいいです。",
    "ダブルベッドの部屋にしたいです。",
    "景色のいい部屋はありますか。",
    "もっと広い部屋はありますか。",
    "禁煙ルームでお願いします。",
    "上の階にしてもらえますか。"
   ],
   "neg": [
    "予約している田中です。",
    "朝食は何時からですか。",
    "チェックアウトは何時ですか。",
    "荷物を預かってもらえますか。",
    "Wi-Fiは使えますか。",
    "ありがとうございます。",
    "トイレはどこですか。",
    "エレベーターはどこですか。",
    "お腹がすきました。"
   ]
  },
  "breakfast_wifi": {
   "pos": [
    "朝食は何時からですか。",
    "朝ごはんはどこで食べますか。",
    "朝食はいくらですか。",
    "Wi-Fiは使えますか。",
    "ワイファイのパスワードを教えてください。",
    "無料のWi-Fiはありますか。",
    "ちょうしょくは付いていますか。",
    "wifiのパスワードは何ですか。",
    "朝食の場所はどこですか。",
    "部屋でもワイファイは使えますか。",
    "朝ご飯は何時までですか。"
   ],
   "neg": [
    "予約している田中です。",
    "禁煙の部屋をお願いします。",
    "チェックアウトは何時ですか。",
    "荷物を預かってもらえますか。",
    "ありがとうございます。",
    "トイレはどこですか。",
    "夕食はいりません。",
    "エレベーターはどこですか。",
    "今日は寒いですね。"
   ]
  },
  "checkout_luggage": {
   "pos": [
    "チェックアウトは何時ですか。",
    "荷物を預かってもらえますか。",
    "チェックアウトのあとも荷物を預けられますか。",
    "にもつをあずかってください。",
    "何時までにチェックアウトすればいいですか。",
    "荷物を預けたいです。",
    "チェックアウトしたいんですが。",
    "チェックアウトの時間を教えてください。",
    "スーツケースを預かっていただけますか。",
    "チェックアウト後も荷物を置いていいですか。",
    "十一時にチェックアウトします。",
    "大きい荷物を預けてもいいですか。"
   ],
   "neg": [
    "予約している田中です。",
    "禁煙の部屋をお願いします。",
    "朝食は何時からですか。",
    "Wi-Fiは使えますか。",
    "ありがとうございます。",
    "トイレはどこですか。",
    "荷物が重いですね。",
    "エレベーターはどこですか。",
    "部屋を変えてもらえますか。"
   ]
  }
 },
 "ja_station_ticket": {
  "dest_ticket": {
   "pos": [
    "東京までの切符をください。",
    "京都まで一枚お願いします。",
    "大阪行きの切符をください。",
    "新宿までお願いします。",
    "東京駅まで行きたいんですが。",
    "きょうとまでのきっぷをください。",
    "横浜までの切符を買いたいです。",
    "浅草までください。",
    "空港までの切符をお願いします。",
    "名古屋までの乗車券をください。",
    "渋谷まで行きたいです。",
    "大阪までのチケットをお願いします。"
   ],
   "neg": [
    "大人二枚お願いします。",
    "何番線ですか。",
    "カードで払います。",
    "ありがとうございました。",
    "次の電車は何時ですか。",
    "片道でお願いします。",
    "トイレはどこですか。",
    "今日は暑いですね。",
    "指定席にしてください。"
   ]
  },
  "ticket_kind": {
   "pos": [
    "大人二枚お願いします。",
    "片道でお願いします。",
    "往復をください。",
    "指定席をお願いします。",
    "自由席でいいです。",
    "大人一人と子供一人です。",
    "こども一まいください。",
    "往復切符を二枚お願いします。",
    "かたみちでおねがいします。",
    "三枚ください。",
    "指定席を二枚ください。",
    "大人一枚、子供二枚です。"
   ],
   "neg": [
    "東京までの切符をください。",
    "何番線ですか。",
    "カードで払います。",
    "ありがとうございました。",
    "次の電車は何時ですか。",
    "トイレはどこですか。",
    "今日は暑いですね。",
    "京都まで行きたいです。",
    "新幹線は何分かかりますか。"
   ]
  },
  "platform_time": {
   "pos": [
    "何番線ですか。",
    "何番ホームから出ますか。",
    "次の電車は何時ですか。",
    "何時に出発しますか。",
    "電車は何時に着きますか。",
    "なんばんせんですか。",
    "次の新幹線は何時ですか。",
    "何時に着きますか。",
    "京都行きは何番線ですか。",
    "一番早い電車は何時ですか。",
    "乗り場はどこですか。",
    "ホームは何番ですか。"
   ],
   "neg": [
    "東京までの切符をください。",
    "大人二枚お願いします。",
    "カードで払います。",
    "ありがとうございました。",
    "片道でお願いします。",
    "トイレはどこですか。",
    "今日は暑いですね。",
    "指定席にしてください。",
    "いくらですか。"
   ]
  },
  "pay_thank": {
   "pos": [
    "カードで払います。",
    "現金でお願いします。",
    "Suicaで払えます。",
    "ありがとうございました。",
    "ありがとうございます。",
    "クレジットカードは使えますか。",
    "どうもありがとう。",
    "げんきんではらいます。",
    "ICカードで払ってもいいですか。",
    "PayPayは使えますか。",
    "カードでお願いします、ありがとうございました。",
    "助かりました、ありがとう。"
   ],
   "neg": [
    "東京までの切符をください。",
    "大人二枚お願いします。",
    "何番線ですか。",
    "片道でお願いします。",
    "次の電車は何時ですか。",
    "トイレはどこですか。",
    "今日は暑いですね。",
    "指定席にしてください。",
    "いくらですか。"
   ]
  }
 },
 "ja_clinic": {
  "first_visit": {
   "pos": [
    "初めてです。",
    "はじめてです。",
    "初診です。",
    "初めて来ました。",
    "診察をお願いします。",
    "受付をお願いします。",
    "診てもらえますか。",
    "予約はしていませんが、診てもらえますか。",
    "この病院は初めてです。",
    "初めての診察です。",
    "診察を受けたいんですが。",
    "初めて来たんですが、どうすればいいですか。"
   ],
   "neg": [
    "頭が痛いです。",
    "昨日からです。",
    "アレルギーはありません。",
    "保険証です。",
    "熱があります。",
    "ありがとうございます。",
    "トイレはどこですか。",
    "今日は暑いですね。",
    "三日前からです。"
   ]
  },
  "symptom": {
   "pos": [
    "頭が痛いです。",
    "熱があります。",
    "せきが出ます。",
    "のどが痛いです。",
    "鼻水が止まりません。",
    "おなかが痛いです。",
    "気分が悪いです。",
    "体がだるいです。",
    "風邪をひいたみたいです。",
    "頭痛がします。",
    "咳が出て、熱もあります。",
    "あたまがいたいです。"
   ],
   "neg": [
    "初めてです。",
    "昨日からです。",
    "アレルギーはありません。",
    "保険証です。",
    "診察をお願いします。",
    "ありがとうございます。",
    "トイレはどこですか。",
    "今日は暑いですね。",
    "元気です。"
   ]
  },
  "duration": {
   "pos": [
    "昨日からです。",
    "三日前からです。",
    "一週間前から痛いです。",
    "今朝からです。",
    "おとといからです。",
    "二日前からせきが出ます。",
    "きのうの夜からです。",
    "先週からずっと熱があります。",
    "三日ぐらい続いています。",
    "朝からです。",
    "一週間くらいです。",
    "昨日の夕方から痛くなりました。"
   ],
   "neg": [
    "頭が痛いです。",
    "初めてです。",
    "アレルギーはありません。",
    "保険証です。",
    "熱があります。",
    "ありがとうございます。",
    "トイレはどこですか。",
    "診察をお願いします。",
    "今日は暑いですね。"
   ]
  },
  "allergy_insurance": {
   "pos": [
    "アレルギーはありません。",
    "薬のアレルギーがあります。",
    "保険証です。",
    "これが保険証です。",
    "パスポートです。",
    "保険証を持っています。",
    "アレルギーはないです。",
    "卵アレルギーがあります。",
    "いつも飲んでいる薬はありません。",
    "海外旅行保険に入っています。",
    "あれるぎーはありません。",
    "保険証はこちらです。"
   ],
   "neg": [
    "頭が痛いです。",
    "初めてです。",
    "昨日からです。",
    "熱があります。",
    "診察をお願いします。",
    "ありがとうございます。",
    "トイレはどこですか。",
    "今日は暑いですね。",
    "三日前からです。"
   ]
  }
 },
 "ja_shopping": {
  "ask_price": {
   "pos": [
    "これはいくらですか。",
    "いくらですか。",
    "これいくらですか。",
    "このシャツはおいくらですか。",
    "値段はいくらですか。",
    "この帽子はいくらですか？",
    "いくらになりますか。",
    "全部でいくらですか。",
    "このお土産はいくらでしょうか。",
    "おいくらですか。",
    "これは何円ですか。",
    "このバッグの値段を教えてください。"
   ],
   "neg": [
    "もっと大きいサイズはありますか。",
    "免税できますか。",
    "カードで払います。",
    "袋をください。",
    "赤はありますか。",
    "ありがとうございます。",
    "トイレはどこですか。",
    "今日は暑いですね。",
    "これをください。"
   ]
  },
  "size_color": {
   "pos": [
    "もう少し大きいサイズはありますか。",
    "Mサイズはありますか。",
    "赤はありますか。",
    "ほかの色はありますか。",
    "小さいサイズをお願いします。",
    "色違いはありますか。",
    "黒のLサイズをください。",
    "これの青はありますか。",
    "もっと小さいのはありますか。",
    "サイズを変えてもいいですか。",
    "おおきいサイズはありますか。",
    "白い色はありますか。"
   ],
   "neg": [
    "これはいくらですか。",
    "免税できますか。",
    "カードで払います。",
    "袋をください。",
    "ありがとうございます。",
    "トイレはどこですか。",
    "今日は暑いですね。",
    "見ているだけです。",
    "割引はありますか。"
   ]
  },
  "tax_free": {
   "pos": [
    "免税できますか。",
    "免税になりますか。",
    "めんぜいはできますか。",
    "税金は戻りますか。",
    "パスポートで免税ができますか。",
    "割引はありますか。",
    "セールですか。",
    "安くなりませんか。",
    "免税の手続きをお願いします。",
    "少し値引きしてもらえますか。",
    "消費税は含まれていますか。",
    "学生割引はありますか。"
   ],
   "neg": [
    "これはいくらですか。",
    "もっと大きいサイズはありますか。",
    "カードで払います。",
    "袋をください。",
    "赤はありますか。",
    "ありがとうございます。",
    "トイレはどこですか。",
    "今日は暑いですね。",
    "これをください。"
   ]
  },
  "pay_bag": {
   "pos": [
    "カードで払います。",
    "現金でお願いします。",
    "袋をください。",
    "袋はいりません。",
    "プレゼント用に包んでもらえますか。",
    "レシートをください。",
    "クレジットカードは使えますか。",
    "ふくろにいれてください。",
    "ラッピングをお願いします。",
    "PayPayで払えますか。",
    "別々に包んでください。",
    "袋は大丈夫です。"
   ],
   "neg": [
    "これはいくらですか。",
    "もっと大きいサイズはありますか。",
    "免税できますか。",
    "赤はありますか。",
    "ありがとうございます。",
    "トイレはどこですか。",
    "今日は暑いですね。",
    "割引はありますか。",
    "見ているだけです。"
   ]
  }
 },
 "ja_self_intro": {
  "say_name": {
   "pos": [
    "田中です。",
    "私は田中といいます。",
    "わたしの名前はキムです。",
    "私はスミスです。",
    "マイクと申します。",
    "名前はさくらです。",
    "ジョンです。",
    "私の名前はリーです。",
    "わたしはたなかです。",
    "ケンと呼んでください。",
    "山田と言います。",
    "私はマリアです。"
   ],
   "neg": [
    "はじめまして。",
    "アメリカから来ました。",
    "趣味は映画です。",
    "あなたは？",
    "よろしくお願いします。",
    "おなかがすきました。",
    "今日は暑いですね。",
    "日本語を勉強しています。",
    "ありがとうございます。"
   ]
  },
  "nice_meet": {
   "pos": [
    "はじめまして。",
    "初めまして。",
    "よろしくお願いします。",
    "どうぞよろしく。",
    "はじめまして、よろしくお願いします。",
    "お会いできてうれしいです。",
    "初めまして、田中です。よろしくお願いします。",
    "よろしくおねがいします。",
    "こちらこそよろしくお願いします。",
    "はじめまして！",
    "ハジメマシテ。",
    "お会いできて光栄です。"
   ],
   "neg": [
    "私は田中です。",
    "アメリカから来ました。",
    "趣味は映画です。",
    "あなたは？",
    "おなかがすきました。",
    "今日は暑いですね。",
    "日本語を勉強しています。",
    "ありがとうございます。",
    "さようなら。"
   ]
  },
  "origin": {
   "pos": [
    "アメリカから来ました。",
    "韓国出身です。",
    "私は中国から来ました。",
    "出身は大阪です。",
    "フランスから来ました。",
    "かんこくからきました。",
    "カナダの出身です。",
    "私はブラジル人です。",
    "オーストラリアから来ました。",
    "台湾出身です。",
    "ドイツから来ました。",
    "日本人ではありません、インドから来ました。",
    "出身は韓国のソウルです。"
   ],
   "neg": [
    "田中です。",
    "はじめまして。",
    "趣味は映画です。",
    "あなたは？",
    "おなかがすきました。",
    "今日は暑いですね。",
    "日本語を勉強しています。",
    "ありがとうございます。",
    "よろしくお願いします。"
   ]
  },
  "hobby": {
   "pos": [
    "趣味は映画です。",
    "趣味は音楽を聞くことです。",
    "サッカーが好きです。",
    "週末はよく料理をします。",
    "しゅみはどくしょです。",
    "旅行が好きです。",
    "ゲームをするのが好きです。",
    "写真を撮るのが趣味です。",
    "休みの日は散歩をします。",
    "ギターを弾くのが好きです。",
    "本を読むことが趣味です。",
    "テニスをしています。"
   ],
   "neg": [
    "田中です。",
    "はじめまして。",
    "アメリカから来ました。",
    "あなたは？",
    "おなかがすきました。",
    "今日は暑いですね。",
    "よろしくお願いします。",
    "ありがとうございます。",
    "学生です。"
   ]
  },
  "ask_back": {
   "pos": [
    "あなたは？",
    "あなたはどうですか。",
    "あなたの趣味は何ですか。",
    "あなたはどこから来ましたか。",
    "そちらはどうですか。",
    "あなたのお名前は？",
    "田中さんは？",
    "あなたも映画が好きですか。",
    "あなたはどうですか？",
    "あなたはなにが好きですか。",
    "あなたはお仕事は何ですか。",
    "わたしは学生です。あなたは？",
    "趣味は何ですか。"
   ],
   "neg": [
    "田中です。",
    "はじめまして。",
    "アメリカから来ました。",
    "趣味は映画です。",
    "おなかがすきました。",
    "今日は暑いですね。",
    "よろしくお願いします。",
    "ありがとうございます。",
    "学生です。"
   ]
  }
 }
}
EXPECT_SHA = "e77e50b2a25afb120e92e29df5654ce8cb7a0622fa06d8fdb17f4d623e7b0908"


def data_hash():
    canon = json.dumps(SENTENCES, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(canon).hexdigest()


def measure(content_path):
    """Measure the sentences against the content file. Returns a dict (no printing)."""
    folder = os.path.dirname(os.path.abspath(content_path))
    old_dir, old_file = M.CONTENT_DIR, M.MISSIONS_FILE
    M.CONTENT_DIR, M.MISSIONS_FILE = folder, os.path.basename(content_path)
    try:
        ja = {m["id"]: m for m in M.load_missions() if m["lang"] == "ja"}
        problems = []
        for mid in sorted(set(ja) | set(SENTENCES)):
            if mid not in ja:
                problems.append("mission %s has sentences but is not in the content (or is broken)" % mid)
            elif mid not in SENTENCES:
                problems.append("mission %s is in the content but has no sentences" % mid)
        rows, under_list, over_list, errors = [], [], [], []
        for mid, goals in SENTENCES.items():
            if mid not in ja:
                continue
            ids = [g["id"] for g in ja[mid]["goals"]]
            for gid in sorted(set(ids) | set(goals)):
                if gid not in ids:
                    problems.append("%s/%s has sentences but the goal is not in the content" % (mid, gid))
                elif gid not in goals:
                    problems.append("%s/%s is in the content but has no sentences" % (mid, gid))
            for gid, v in goals.items():
                if gid not in ids:
                    continue
                if len(v["pos"]) < MIN_POS or len(v["neg"]) < MIN_NEG:
                    problems.append("%s/%s has %d pos / %d neg sentences (need >= %d / >= %d)"
                                    % (mid, gid, len(v["pos"]), len(v["neg"]), MIN_POS, MIN_NEG))
                under = over = 0
                for s in v["pos"]:
                    try:
                        reached = gid in M.check_text("ja", mid, s)["new"]
                    except Exception as e:
                        errors.append((mid, gid, "pos", s, repr(e)))
                        reached = False
                    if not reached:
                        under += 1
                        under_list.append((mid, gid, s))
                for s in v["neg"]:
                    try:
                        reached = gid in M.check_text("ja", mid, s)["new"]
                    except Exception as e:
                        errors.append((mid, gid, "neg", s, repr(e)))
                        reached = False
                    if reached:
                        over += 1
                        over_list.append((mid, gid, s))
                rows.append({"mission": mid, "goal": gid, "pos": len(v["pos"]), "neg": len(v["neg"]), "under": under, "over": over})
        return {"rows": rows, "under_list": under_list, "over_list": over_list, "errors": errors, "problems": problems}
    finally:
        M.CONTENT_DIR, M.MISSIONS_FILE = old_dir, old_file


def judge(r):
    """The pass/fail verdict of a measurement. Returns (ok, list of reason strings)."""
    why = list(r["problems"])
    why += ["error on %s/%s %s %r: %s" % e for e in r["errors"]]
    pos = sum(x["pos"] for x in r["rows"])
    neg = sum(x["neg"] for x in r["rows"])
    under = sum(x["under"] for x in r["rows"])
    over = sum(x["over"] for x in r["rows"])
    if not r["rows"] or pos == 0 or neg == 0:
        why.append("nothing was measured")
        return False, why
    if under / pos > MAX_UNDER_TOTAL:
        why.append("total under rate %.1f%% > %.0f%%" % (100.0 * under / pos, 100 * MAX_UNDER_TOTAL))
    if over / neg > MAX_OVER_TOTAL:
        why.append("total over rate %.1f%% > %.0f%%" % (100.0 * over / neg, 100 * MAX_OVER_TOTAL))
    for x in r["rows"]:
        if x["pos"] and x["under"] / x["pos"] > MAX_UNDER_GOAL:
            why.append("%s/%s under rate %.1f%% > %.0f%%" % (x["mission"], x["goal"], 100.0 * x["under"] / x["pos"], 100 * MAX_UNDER_GOAL))
    return not why, why


def report(r, quiet=False):
    pos = sum(x["pos"] for x in r["rows"])
    neg = sum(x["neg"] for x in r["rows"])
    under = sum(x["under"] for x in r["rows"])
    over = sum(x["over"] for x in r["rows"])
    if not quiet:
        print("%-18s %-18s %5s %5s %9s %9s" % ("mission", "goal", "pos", "neg", "under", "over"))
        for x in r["rows"]:
            print("%-18s %-18s %5d %5d %4d %4.0f%% %4d %4.0f%%" % (
                x["mission"], x["goal"], x["pos"], x["neg"], x["under"], 100.0 * x["under"] / max(1, x["pos"]),
                x["over"], 100.0 * x["over"] / max(1, x["neg"])))
    print("TOTAL goals=%d pos=%d neg=%d under=%d (%.1f%%) over=%d (%.1f%%)" % (
        len(r["rows"]), pos, neg, under, 100.0 * under / max(1, pos), over, 100.0 * over / max(1, neg)))
    return pos, neg, under, over


def broken_copy(src, mode, only=None):
    """write a copy of the content into a new folder with broken rules; returns the path of the copy.
    mode 'dead': the goal's patterns become 'zzzz' (nothing can match). mode 'wide': the pattern becomes '.' (anything matches)."""
    with open(src, "r", encoding="utf-8") as f:
        data = json.load(f)
    pat = "zzzz" if mode == "dead" else "."
    for m in data["missions"]:
        if m.get("lang") != "ja":
            continue
        for g in m["goals"]:
            if only is None or (m["id"], g["id"]) == only:
                g["match"] = {"any": [pat]}
    folder = tempfile.mkdtemp(prefix="b2t_")
    path = os.path.join(folder, "missions.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    return path


def selfchecks(src):
    """the test must be able to fail: judge() has to reject broken content (same measure + judge as the real run)"""
    ok_all = True
    first = None
    with open(src, "r", encoding="utf-8") as f:
        for m in json.load(f)["missions"]:
            if m.get("lang") == "ja" and first is None:
                first = (m["id"], m["goals"][0]["id"])
    cases = [("all rules replaced by 'zzzz' -> under 100%", "dead", None, "under"),
             ("one goal %s/%s replaced by 'zzzz' -> that goal under 100%%" % first, "dead", first, "goal"),
             ("all rules replaced by '.' -> over 100%", "wide", None, "over")]
    for label, mode, only, kind in cases:
        path = broken_copy(src, mode, only)
        try:
            r = measure(path)
        finally:
            shutil.rmtree(os.path.dirname(path), ignore_errors=True)
        ok, why = judge(r)
        pos = sum(x["pos"] for x in r["rows"]) or 1
        neg = sum(x["neg"] for x in r["rows"]) or 1
        under = sum(x["under"] for x in r["rows"])
        over = sum(x["over"] for x in r["rows"])
        if kind == "under":
            shaped = under == pos
        elif kind == "over":
            shaped = over == neg
        else:
            row = [x for x in r["rows"] if (x["mission"], x["goal"]) == only]
            shaped = bool(row) and row[0]["under"] == row[0]["pos"]
        if (not ok) and shaped:
            print("selfcheck FAIL-as-expected %s (under %d/%d, over %d/%d)" % (label, under, pos, over, neg))
        else:
            ok_all = False
            print("selfcheck NOT-DETECTED %s (judge ok=%s, under %d/%d, over %d/%d)" % (label, ok, under, pos, over, neg))
    return ok_all


def main(argv):
    content, quiet, do_self = DEFAULT_CONTENT, False, True
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--content" and i + 1 < len(argv):
            content = argv[i + 1]
            i += 1
        elif a == "--quiet":
            quiet = True
        elif a == "--no-selfcheck":
            do_self = False
        else:
            print("unknown argument: %s" % a)
            return 2
        i += 1
    fails = 0
    h = data_hash()
    print("sentence data sha256 (canonical json) %s" % h)
    if h != EXPECT_SHA:
        print("FAIL sentence data changed since the measurement (expected %s)" % EXPECT_SHA)
        fails += 1
    print("content: %s" % content)
    try:
        r = measure(content)
    except Exception as e:
        print("FAIL cannot measure the content %s: %r" % (content, e))
        print("RESULT %d FAIL" % (fails + 1))
        return 1
    report(r, quiet)
    ok, why = judge(r)
    print("--- under (correct sentence NOT accepted): %d ---" % len(r["under_list"]))
    for mid, gid, s in r["under_list"]:
        print("UNDER %s/%s: %s" % (mid, gid, s))
    print("--- over (wrong sentence accepted): %d ---" % len(r["over_list"]))
    for mid, gid, s in r["over_list"]:
        print("OVER  %s/%s: %s" % (mid, gid, s))
    if ok:
        print("PASS thresholds (under <= %.0f%% total, <= %.0f%% per goal, over <= %.0f%%)" % (100 * MAX_UNDER_TOTAL, 100 * MAX_UNDER_GOAL, 100 * MAX_OVER_TOTAL))
    else:
        for w in why:
            print("FAIL %s" % w)
        fails += len(why)
    if do_self:
        if not selfchecks(content):
            fails += 1
            print("FAIL selfcheck: the test did not detect broken content")
    print("RESULT %s" % ("0 FAIL" if fails == 0 else "%d FAIL" % fails))
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
