#!/usr/bin/env python3
"""Collect book-prize winners from Wikidata for Discover's Prize winners list.

Prizes change once a year, so Leaf carries the winners in the app instead of asking
Wikidata from every phone (its public query service is heavily rate limited).
Run this when a prize announces a new winner and commit the regenerated file:

    python3 -I scripts/fetch_prize_winners.py --output build/prize-winners.json

The JSON is reviewed by hand and turned into LeafReader/Services/Catalog/PrizeWinners.swift.
Requests are spaced out; one run makes about 30 requests.
"""
import argparse
import json
import sys
import time
import urllib.parse
import urllib.request

API = "https://www.wikidata.org/w/api.php"
AGENT = "LeafReader/1.47 (book discovery; prize winners)"
PRIZES = {
    "booker": "Q160082",
    "internationalBooker": "Q2052291",
    "pulitzer": "Q833633",
    "nationalBook": "Q3873144",
    "hugo": "Q255032",
    "nebula": "Q266012",
}


def get(params, pause):
    url = API + "?" + urllib.parse.urlencode({**params, "format": "json"})
    for attempt in range(6):
        time.sleep(pause * (attempt + 1))
        request = urllib.request.Request(url, headers={"User-Agent": AGENT})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code != 429:
                raise
            print(f"rate limited, waiting ({attempt + 1})", file=sys.stderr)
            time.sleep(60)
    raise SystemExit("Wikidata kept refusing requests")


def label(entity, languages):
    for language in languages:
        value = entity.get("labels", {}).get(language, {}).get("value")
        if value:
            return value
    return ""


def values(claims, prop):
    result = []
    for statement in claims.get(prop, []):
        value = statement.get("mainsnak", {}).get("datavalue", {}).get("value")
        if value is not None:
            result.append(value)
    return result


def year(time_value):
    text = (time_value or {}).get("time", "")
    return int(text[1:5]) if len(text) > 5 and text[1:5].isdigit() else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--pause", type=float, default=4)
    args = parser.parse_args()
    result = {}
    for key, award in PRIZES.items():
        search = get({"action": "query", "list": "search", "srlimit": 200,
                      "srsearch": f"haswbstatement:P166={award} -haswbstatement:P31=Q5"}, args.pause)
        ids = [row["title"] for row in search["query"]["search"]]
        works, authors = {}, set()
        for start in range(0, len(ids), 50):
            batch = get({"action": "wbgetentities", "ids": "|".join(ids[start:start + 50]),
                         "props": "labels|claims", "languages": "en|zh"}, args.pause)
            for wid, entity in batch.get("entities", {}).items():
                claims = entity.get("claims", {})
                won = [s for s in claims.get("P166", [])
                       if s.get("mainsnak", {}).get("datavalue", {}).get("value", {}).get("id") == award]
                when = [year(q.get("datavalue", {}).get("value"))
                        for s in won for q in s.get("qualifiers", {}).get("P585", [])]
                writers = [v["id"] for v in values(claims, "P50")]
                authors.update(writers)
                works[wid] = {
                    "id": wid, "title": label(entity, ["en"]), "zh": label(entity, ["zh"]),
                    "authors": writers, "year": next((y for y in when if y), None),
                    "published": next((year(v) for v in values(claims, "P577") if year(v)), None),
                    "kinds": [v["id"] for v in values(claims, "P31")],
                    "isbns": [v for v in values(claims, "P212") + values(claims, "P957") if isinstance(v, str)],
                }
        names = {}
        author_ids = sorted(authors)
        for start in range(0, len(author_ids), 50):
            batch = get({"action": "wbgetentities", "ids": "|".join(author_ids[start:start + 50]),
                         "props": "labels", "languages": "en|zh"}, args.pause)
            for aid, entity in batch.get("entities", {}).items():
                names[aid] = {"en": label(entity, ["en"]), "zh": label(entity, ["zh"])}
        for work in works.values():
            work["author"] = ", ".join(names.get(a, {}).get("en", "") for a in work["authors"] if names.get(a, {}).get("en"))
        result[key] = sorted(works.values(), key=lambda w: (-(w["year"] or 0), w["title"]))
        print(f"{key}: {len(result[key])} works", file=sys.stderr)
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
