import json
import re
import urllib.request
from datetime import datetime
from bs4 import BeautifulSoup

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )
}

TARGET_URL = "https://liveonsat.com/quickindex.html"


def fetch_matches():
    matches = []
    try:
        req = urllib.request.Request(TARGET_URL, headers=HEADERS)
        html = urllib.request.urlopen(req, timeout=20).read().decode(
            "utf-8", errors="ignore"
        )
        soup = BeautifulSoup(html, "html.parser")

        tables = soup.find_all("table")
        for table in tables:
            rows = table.find_all("tr")
            current_league = "مباراة رياضية"

            for row in rows:
                text = row.get_text(separator=" ").strip()

                if "league" in row.get("class", []) or "comp" in text.lower():
                    current_league = text
                    continue

                if " vs " in text or " v " in text:
                    cols = row.find_all("td")
                    if len(cols) >= 2:
                        match_name = cols[0].get_text(strip=True)
                        match_time = cols[1].get_text(strip=True)

                        channels = []
                        links = row.find_all("a")
                        for link in links:
                            ch_name = link.get_text(strip=True)
                            if not ch_name:
                                continue

                            sat_info = link.get("title", "")
                            sat_match = re.search(
                                r"(\d+\.?\d*°?[EW])", sat_info
                            )
                            sat_orbit = (
                                sat_match.group(1).replace("°", "")
                                if sat_match
                                else "SAT"
                            )

                            channels.append(
                                {"name": ch_name, "orbit": sat_orbit}
                            )

                        if channels:
                            matches.append(
                                {
                                    "match": match_name,
                                    "league": current_league,
                                    "time": match_time,
                                    "channels": channels,
                                }
                            )
    except Exception as e:
        print(f"Scraper error: {e}")

    return matches


def main():
    data = fetch_matches()
    output = {
        "updated": datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC"),
        "total": len(data),
        "matches": data,
    }

    with open("matches.json", "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)

    print(f"Successfully saved {len(data)} matches to matches.json")


if __name__ == "__main__":
    main()
