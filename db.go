package main

import (
	"database/sql"

	_ "modernc.org/sqlite"
)

const schema = `
CREATE TABLE IF NOT EXISTS products (
    code         TEXT PRIMARY KEY,
    series       TEXT NOT NULL,
    category     TEXT NOT NULL,
    height_mm    REAL NOT NULL,
    width_mm     REAL NOT NULL,
    web_thick    REAL NOT NULL,
    flange_thick REAL NOT NULL,
    unit_weight  REAL NOT NULL,
    application  TEXT
);

CREATE TABLE IF NOT EXISTS grades (
    code        TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    unit_price  REAL NOT NULL,
    description TEXT
);

CREATE TABLE IF NOT EXISTS quotes (
    id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    customer               TEXT NOT NULL,
    project                TEXT,
    sales_user_id          TEXT,
    total_weight_kg        REAL NOT NULL,
    subtotal_ntd           REAL NOT NULL,
    manual_discount_factor REAL NOT NULL DEFAULT 1.0,
    manual_concession_ntd  REAL NOT NULL DEFAULT 0,
    manual_surcharge_ntd   REAL NOT NULL DEFAULT 0,
    final_total_ntd        REAL NOT NULL,
    note                   TEXT,
    items_json             TEXT NOT NULL,
    created_at             DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_quotes_customer ON quotes(customer);
CREATE INDEX IF NOT EXISTS idx_quotes_user     ON quotes(sales_user_id);
`

// 種子資料 — 涵蓋柱、樑、兩用三類,共 10 筆
var seedProducts = []Product{
	{Code: "HW200x200", Series: "廣幅 HW", Category: "柱材", HeightMm: 200, WidthMm: 200, WebThick: 8, FlangeThick: 12, UnitWeight: 49.9, Application: "廠房、住宅常用柱"},
	{Code: "HW300x300", Series: "廣幅 HW", Category: "柱材", HeightMm: 300, WidthMm: 300, WebThick: 10, FlangeThick: 15, UnitWeight: 94.0, Application: "中高樓層柱"},
	{Code: "HW400x400", Series: "廣幅 HW", Category: "柱材", HeightMm: 400, WidthMm: 400, WebThick: 13, FlangeThick: 21, UnitWeight: 172.0, Application: "高樓層主柱"},
	{Code: "HM300x200", Series: "中幅 HM", Category: "柱樑兩用", HeightMm: 294, WidthMm: 200, WebThick: 8, FlangeThick: 12, UnitWeight: 56.8, Application: "中大跨度樑"},
	{Code: "HM400x300", Series: "中幅 HM", Category: "柱樑兩用", HeightMm: 390, WidthMm: 300, WebThick: 10, FlangeThick: 16, UnitWeight: 107.0, Application: "大跨度主樑"},
	{Code: "HN200x100", Series: "細幅 HN", Category: "樑材", HeightMm: 200, WidthMm: 100, WebThick: 5.5, FlangeThick: 8, UnitWeight: 21.3, Application: "輕型樑"},
	{Code: "HN300x150", Series: "細幅 HN", Category: "樑材", HeightMm: 300, WidthMm: 150, WebThick: 6.5, FlangeThick: 9, UnitWeight: 36.7, Application: "常用主樑"},
	{Code: "HN400x200", Series: "細幅 HN", Category: "樑材", HeightMm: 400, WidthMm: 200, WebThick: 8, FlangeThick: 13, UnitWeight: 66.0, Application: "鋼骨建築最常用樑"},
	{Code: "HN500x200", Series: "細幅 HN", Category: "樑材", HeightMm: 500, WidthMm: 200, WebThick: 10, FlangeThick: 16, UnitWeight: 89.6, Application: "重型主樑"},
	{Code: "HN700x300", Series: "細幅 HN", Category: "樑材", HeightMm: 700, WidthMm: 300, WebThick: 13, FlangeThick: 24, UnitWeight: 185.0, Application: "橋樑、大跨度結構"},
}

var seedGrades = []Grade{
	{Code: "SS400", Name: "一般結構用碳鋼", UnitPrice: 28.5, Description: "降伏強度 245 MPa,最常用,價格基準"},
	{Code: "SM490", Name: "銲接結構用鋼", UnitPrice: 31.2, Description: "降伏強度 325 MPa,銲接性與韌性較佳"},
	{Code: "SN490", Name: "建築結構耐震用鋼", UnitPrice: 33.0, Description: "降伏強度 325 MPa,耐震建築指定材"},
	{Code: "A572", Name: "美規高張力鋼", UnitPrice: 32.0, Description: "降伏強度 345 MPa,大跨度高樓常用"},
}

func initDB(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	if _, err := db.Exec(schema); err != nil {
		_ = db.Close()
		return nil, err
	}
	if err := seedIfEmpty(db); err != nil {
		_ = db.Close()
		return nil, err
	}
	return db, nil
}

func seedIfEmpty(db *sql.DB) error {
	var n int
	if err := db.QueryRow("SELECT COUNT(*) FROM products").Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return nil
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	for _, p := range seedProducts {
		_, err := tx.Exec(
			`INSERT INTO products (code, series, category, height_mm, width_mm, web_thick, flange_thick, unit_weight, application) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			p.Code, p.Series, p.Category, p.HeightMm, p.WidthMm, p.WebThick, p.FlangeThick, p.UnitWeight, p.Application,
		)
		if err != nil {
			return err
		}
	}
	for _, g := range seedGrades {
		_, err := tx.Exec(
			`INSERT INTO grades (code, name, unit_price, description) VALUES (?, ?, ?, ?)`,
			g.Code, g.Name, g.UnitPrice, g.Description,
		)
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}
