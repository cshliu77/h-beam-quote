package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
)

// ─────────────────────────────────────────────────────────
// Products
// ─────────────────────────────────────────────────────────

func listProducts(db *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		category := c.Query("category")
		var rows *sql.Rows
		var err error
		if category != "" {
			rows, err = db.Query(`SELECT code, series, category, height_mm, width_mm, web_thick, flange_thick, unit_weight, application FROM products WHERE category = ? ORDER BY code`, category)
		} else {
			rows, err = db.Query(`SELECT code, series, category, height_mm, width_mm, web_thick, flange_thick, unit_weight, application FROM products ORDER BY code`)
		}
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		defer rows.Close()

		products := []Product{}
		for rows.Next() {
			var p Product
			if err := rows.Scan(&p.Code, &p.Series, &p.Category, &p.HeightMm, &p.WidthMm, &p.WebThick, &p.FlangeThick, &p.UnitWeight, &p.Application); err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
				return
			}
			products = append(products, p)
		}
		c.JSON(http.StatusOK, gin.H{"products": products, "count": len(products)})
	}
}

func getProduct(db *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		code := c.Param("code")
		var p Product
		err := db.QueryRow(
			`SELECT code, series, category, height_mm, width_mm, web_thick, flange_thick, unit_weight, application FROM products WHERE code = ?`,
			code,
		).Scan(&p.Code, &p.Series, &p.Category, &p.HeightMm, &p.WidthMm, &p.WebThick, &p.FlangeThick, &p.UnitWeight, &p.Application)
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "product not found", "code": code})
			return
		}
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, p)
	}
}

func listGrades(db *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		rows, err := db.Query(`SELECT code, name, unit_price, description FROM grades ORDER BY code`)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		defer rows.Close()
		grades := []Grade{}
		for rows.Next() {
			var g Grade
			if err := rows.Scan(&g.Code, &g.Name, &g.UnitPrice, &g.Description); err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
				return
			}
			grades = append(grades, g)
		}
		c.JSON(http.StatusOK, gin.H{"grades": grades, "count": len(grades)})
	}
}

// ─────────────────────────────────────────────────────────
// Compute helper — 共用計算邏輯
//
// 公式:F = S × f - C + G
//   S = 小計;f = 手動係數;C = 折讓;G = 加成
//
// 驗證:
//   - 0 < f ≤ 1 (factor=0 視為未指定,默認 1.0)
//   - C ≥ 0,G ≥ 0
//   - C × G == 0(互斥)
//   - F ≥ 0
// ─────────────────────────────────────────────────────────

func computeQuote(db *sql.DB, items []QuoteItem, factor, concession, surcharge float64) (*QuoteResponse, int, error) {
	// 標準化:factor=0 視為未指定
	if factor == 0 {
		factor = 1.0
	}
	if factor < 0 || factor > 1 {
		return nil, http.StatusBadRequest, errors.New("manual_discount_factor must be in (0, 1]")
	}
	if concession < 0 {
		return nil, http.StatusBadRequest, errors.New("manual_concession_ntd must be >= 0")
	}
	if surcharge < 0 {
		return nil, http.StatusBadRequest, errors.New("manual_surcharge_ntd must be >= 0")
	}
	if concession > 0 && surcharge > 0 {
		return nil, http.StatusBadRequest, errors.New("manual_concession_ntd and manual_surcharge_ntd are mutually exclusive")
	}

	resp := &QuoteResponse{Items: []QuoteLine{}}
	for _, item := range items {
		var unitWeight float64
		err := db.QueryRow(`SELECT unit_weight FROM products WHERE code = ?`, item.ProductCode).Scan(&unitWeight)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, http.StatusBadRequest, errors.New("product not found: " + item.ProductCode)
		}
		if err != nil {
			return nil, http.StatusInternalServerError, err
		}
		var unitPrice float64
		err = db.QueryRow(`SELECT unit_price FROM grades WHERE code = ?`, item.Grade).Scan(&unitPrice)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, http.StatusBadRequest, errors.New("grade not found: " + item.Grade)
		}
		if err != nil {
			return nil, http.StatusInternalServerError, err
		}
		weight := item.LengthM * float64(item.Quantity) * unitWeight
		lineSubtotal := weight * unitPrice
		resp.Items = append(resp.Items, QuoteLine{
			ProductCode:    item.ProductCode,
			Grade:          item.Grade,
			LengthM:        item.LengthM,
			Quantity:       item.Quantity,
			UnitWeightKgM:  unitWeight,
			UnitPriceNtdKg: unitPrice,
			WeightKg:       weight,
			LineSubtotal:   lineSubtotal,
		})
		resp.TotalWeightKg += weight
		resp.SubtotalNtd += lineSubtotal
	}

	// 手動議價(無階梯自動折扣)
	resp.ManualDiscountFactor = factor
	afterFactor := resp.SubtotalNtd * factor
	resp.ManualFactorNtd = resp.SubtotalNtd - afterFactor
	resp.ManualConcessionNtd = concession
	resp.ManualSurchargeNtd = surcharge

	resp.FinalTotalNtd = afterFactor - concession + surcharge

	if resp.FinalTotalNtd < 0 {
		return nil, http.StatusBadRequest, errors.New("final total would be negative; check concession/surcharge values")
	}

	// 計算有效折扣率(可正可負)
	if resp.SubtotalNtd > 0 {
		resp.EffectiveDiscountRate = (resp.SubtotalNtd - resp.FinalTotalNtd) / resp.SubtotalNtd
	}

	// 標籤
	resp.AdjustmentType = describeAdjustment(factor < 1.0 || concession > 0, surcharge > 0)

	return resp, http.StatusOK, nil
}

func describeAdjustment(hasDiscount, hasSurcharge bool) string {
	switch {
	case !hasDiscount && !hasSurcharge:
		return "原價"
	case hasDiscount:
		return "折讓"
	case hasSurcharge:
		return "加成"
	}
	return "原價"
}

// POST /api/quotes — 純計算(可含手動議價),不保存
func calculateQuote(db *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		var req QuoteRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		resp, status, err := computeQuote(db, req.Items, req.ManualDiscountFactor, req.ManualConcessionNtd, req.ManualSurchargeNtd)
		if err != nil {
			c.JSON(status, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, resp)
	}
}

// POST /api/quotes/match — 反向:給目標價,計算所需折讓或加成
func matchTargetPrice(db *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		var req MatchTargetRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}

		// 先用 factor=1, concession=0, surcharge=0 算出 base 結果(只算小計)
		base, status, err := computeQuote(db, req.Items, 1.0, 0, 0)
		if err != nil {
			c.JSON(status, gin.H{"error": err.Error()})
			return
		}

		target := req.TargetFinalNtd
		subtotal := base.SubtotalNtd

		resp := MatchTargetResponse{
			SubtotalNtd:    subtotal,
			TargetFinalNtd: target,
			FinalTotalNtd:  target,
		}

		switch {
		case target < subtotal:
			resp.ImpliedConcessionNtd = subtotal - target
			resp.AdjustmentType = "折讓"
		case target > subtotal:
			resp.ImpliedSurchargeNtd = target - subtotal
			resp.AdjustmentType = "加成"
		default:
			resp.AdjustmentType = "原價"
		}

		if subtotal > 0 {
			resp.EffectiveDiscountRate = (subtotal - target) / subtotal
		}

		c.JSON(http.StatusOK, resp)
	}
}

// ─────────────────────────────────────────────────────────
// Saved quotes — 業務員確認後存進 DB,Memory Bank 用 quote_id 索引
// ─────────────────────────────────────────────────────────

// POST /api/quotes/save
func saveQuote(db *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		var req SaveQuoteRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		resp, status, err := computeQuote(db, req.Items, req.ManualDiscountFactor, req.ManualConcessionNtd, req.ManualSurchargeNtd)
		if err != nil {
			c.JSON(status, gin.H{"error": err.Error()})
			return
		}
		itemsJSON, err := json.Marshal(resp.Items)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		result, err := db.Exec(
			`INSERT INTO quotes (
                customer, project, sales_user_id,
                total_weight_kg, subtotal_ntd,
                manual_discount_factor, manual_concession_ntd, manual_surcharge_ntd,
                final_total_ntd, note, items_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			req.Customer, req.Project, req.SalesUserID,
			resp.TotalWeightKg, resp.SubtotalNtd,
			resp.ManualDiscountFactor, resp.ManualConcessionNtd, resp.ManualSurchargeNtd,
			resp.FinalTotalNtd, req.Note, string(itemsJSON),
		)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		id, _ := result.LastInsertId()

		var createdAt string
		_ = db.QueryRow(`SELECT created_at FROM quotes WHERE id = ?`, id).Scan(&createdAt)

		c.JSON(http.StatusCreated, SavedQuote{
			ID:                   id,
			Customer:             req.Customer,
			Project:              req.Project,
			SalesUserID:          req.SalesUserID,
			TotalWeightKg:        resp.TotalWeightKg,
			SubtotalNtd:          resp.SubtotalNtd,
			ManualDiscountFactor: resp.ManualDiscountFactor,
			ManualConcessionNtd:  resp.ManualConcessionNtd,
			ManualSurchargeNtd:   resp.ManualSurchargeNtd,
			FinalTotalNtd:        resp.FinalTotalNtd,
			Note:                 req.Note,
			Items:                resp.Items,
			CreatedAt:            createdAt,
		})
	}
}

// GET /api/quotes/:id
func getQuoteByID(db *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		idStr := c.Param("id")
		id, err := strconv.ParseInt(idStr, 10, 64)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid id"})
			return
		}
		var q SavedQuote
		var itemsJSON string
		err = db.QueryRow(
			`SELECT id, customer, COALESCE(project, ''), COALESCE(sales_user_id, ''),
                total_weight_kg, subtotal_ntd,
                manual_discount_factor, manual_concession_ntd, manual_surcharge_ntd,
                final_total_ntd, COALESCE(note, ''), items_json, created_at
             FROM quotes WHERE id = ?`,
			id,
		).Scan(
			&q.ID, &q.Customer, &q.Project, &q.SalesUserID,
			&q.TotalWeightKg, &q.SubtotalNtd,
			&q.ManualDiscountFactor, &q.ManualConcessionNtd, &q.ManualSurchargeNtd,
			&q.FinalTotalNtd, &q.Note, &itemsJSON, &q.CreatedAt,
		)
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "quote not found", "id": id})
			return
		}
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		if err := json.Unmarshal([]byte(itemsJSON), &q.Items); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "items decode: " + err.Error()})
			return
		}
		c.JSON(http.StatusOK, q)
	}
}

// GET /api/quotes — 可用 ?customer= 或 ?sales_user_id= 過濾
func listSavedQuotes(db *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		customer := c.Query("customer")
		userID := c.Query("sales_user_id")

		query := `SELECT id, customer, COALESCE(project, ''), total_weight_kg, final_total_ntd, created_at FROM quotes`
		args := []any{}
		conds := []string{}
		if customer != "" {
			conds = append(conds, "customer = ?")
			args = append(args, customer)
		}
		if userID != "" {
			conds = append(conds, "sales_user_id = ?")
			args = append(args, userID)
		}
		if len(conds) > 0 {
			query += " WHERE " + conds[0]
			for i := 1; i < len(conds); i++ {
				query += " AND " + conds[i]
			}
		}
		query += " ORDER BY id DESC LIMIT 50"

		rows, err := db.Query(query, args...)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		defer rows.Close()

		quotes := []QuoteSummary{}
		for rows.Next() {
			var q QuoteSummary
			if err := rows.Scan(&q.ID, &q.Customer, &q.Project, &q.TotalWeightKg, &q.FinalTotalNtd, &q.CreatedAt); err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
				return
			}
			quotes = append(quotes, q)
		}
		c.JSON(http.StatusOK, gin.H{"quotes": quotes, "count": len(quotes)})
	}
}
