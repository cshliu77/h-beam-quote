package main

// Product 對應 products 資料表的列
type Product struct {
	Code        string  `json:"code"`
	Series      string  `json:"series"`
	Category    string  `json:"category"`
	HeightMm    float64 `json:"height_mm"`
	WidthMm     float64 `json:"width_mm"`
	WebThick    float64 `json:"web_thick_mm"`
	FlangeThick float64 `json:"flange_thick_mm"`
	UnitWeight  float64 `json:"unit_weight_kg_per_m"`
	Application string  `json:"application"`
}

// Grade 對應 grades 資料表的列
type Grade struct {
	Code        string  `json:"code"`
	Name        string  `json:"name"`
	UnitPrice   float64 `json:"unit_price_ntd_per_kg"`
	Description string  `json:"description"`
}

type QuoteItem struct {
	ProductCode string  `json:"product_code" binding:"required"`
	Grade       string  `json:"grade" binding:"required"`
	LengthM     float64 `json:"length_m" binding:"required,gt=0"`
	Quantity    int     `json:"quantity" binding:"required,gt=0"`
}

// QuoteRequest /api/quotes 的請求 body
// 含選填的業務手動議價:折扣係數、折讓、加成(後兩者互斥)
type QuoteRequest struct {
	Items                []QuoteItem `json:"items" binding:"required,min=1"`
	ManualDiscountFactor float64     `json:"manual_discount_factor,omitempty"` // 0 < f ≤ 1,預設 1.0
	ManualConcessionNtd  float64     `json:"manual_concession_ntd,omitempty"`  // ≥ 0,預設 0
	ManualSurchargeNtd   float64     `json:"manual_surcharge_ntd,omitempty"`   // ≥ 0,預設 0(與 concession 互斥)
}

// MatchTargetRequest /api/quotes/match 的 body — 業務指定目標總價,系統反推折讓或加成
type MatchTargetRequest struct {
	Items          []QuoteItem `json:"items" binding:"required,min=1"`
	TargetFinalNtd float64     `json:"target_final_ntd" binding:"required,gt=0"`
}

// SaveQuoteRequest 保存報價的 body — 業務員確認後送出
type SaveQuoteRequest struct {
	Customer             string      `json:"customer" binding:"required"`
	Project              string      `json:"project,omitempty"`
	SalesUserID          string      `json:"sales_user_id,omitempty"`
	Items                []QuoteItem `json:"items" binding:"required,min=1"`
	ManualDiscountFactor float64     `json:"manual_discount_factor,omitempty"`
	ManualConcessionNtd  float64     `json:"manual_concession_ntd,omitempty"`
	ManualSurchargeNtd   float64     `json:"manual_surcharge_ntd,omitempty"`
	Note                 string      `json:"note,omitempty"` // 議價理由備註,Memory Bank 萃取用
}

type QuoteLine struct {
	ProductCode    string  `json:"product_code"`
	Grade          string  `json:"grade"`
	LengthM        float64 `json:"length_m"`
	Quantity       int     `json:"quantity"`
	UnitWeightKgM  float64 `json:"unit_weight_kg_per_m"`
	UnitPriceNtdKg float64 `json:"unit_price_ntd_per_kg"`
	WeightKg       float64 `json:"weight_kg"`
	LineSubtotal   float64 `json:"line_subtotal_ntd"`
}

// QuoteResponse — calculate / save 的計算結果(完整議價軌跡)
type QuoteResponse struct {
	Items                 []QuoteLine `json:"items"`
	TotalWeightKg         float64     `json:"total_weight_kg"`
	SubtotalNtd           float64     `json:"subtotal_ntd"`            // 原始小計
	ManualDiscountFactor  float64     `json:"manual_discount_factor"`  // 手動折扣係數
	ManualFactorNtd       float64     `json:"manual_factor_ntd"`       // 係數造成的折扣金額
	ManualConcessionNtd   float64     `json:"manual_concession_ntd"`   // 手動折讓
	ManualSurchargeNtd    float64     `json:"manual_surcharge_ntd"`    // 手動加成
	FinalTotalNtd         float64     `json:"final_total_ntd"`         // 最終一口價
	AdjustmentType        string      `json:"adjustment_type"`         // 原價/折讓/加成
	EffectiveDiscountRate float64     `json:"effective_discount_rate"` // (S-F)/S,可正(折扣)可負(加成)
}

// SavedQuote — DB 內列(/api/quotes/{id} 與 /api/quotes 列表)
type SavedQuote struct {
	ID                   int64       `json:"id"`
	Customer             string      `json:"customer"`
	Project              string      `json:"project,omitempty"`
	SalesUserID          string      `json:"sales_user_id,omitempty"`
	TotalWeightKg        float64     `json:"total_weight_kg"`
	SubtotalNtd          float64     `json:"subtotal_ntd"`
	ManualDiscountFactor float64     `json:"manual_discount_factor"`
	ManualConcessionNtd  float64     `json:"manual_concession_ntd"`
	ManualSurchargeNtd   float64     `json:"manual_surcharge_ntd"`
	FinalTotalNtd        float64     `json:"final_total_ntd"`
	Note                 string      `json:"note,omitempty"`
	Items                []QuoteLine `json:"items"`
	CreatedAt            string      `json:"created_at"`
}

// QuoteSummary — list 用的精簡版
type QuoteSummary struct {
	ID            int64   `json:"id"`
	Customer      string  `json:"customer"`
	Project       string  `json:"project,omitempty"`
	TotalWeightKg float64 `json:"total_weight_kg"`
	FinalTotalNtd float64 `json:"final_total_ntd"`
	CreatedAt     string  `json:"created_at"`
}

// MatchTargetResponse — /api/quotes/match 回傳
type MatchTargetResponse struct {
	SubtotalNtd           float64 `json:"subtotal_ntd"`
	TargetFinalNtd        float64 `json:"target_final_ntd"`
	ImpliedConcessionNtd  float64 `json:"implied_concession_ntd"`  // > 0 表示要折讓
	ImpliedSurchargeNtd   float64 `json:"implied_surcharge_ntd"`   // > 0 表示要加成
	FinalTotalNtd         float64 `json:"final_total_ntd"`         // = target
	AdjustmentType        string  `json:"adjustment_type"`         // 折讓/加成/原價
	EffectiveDiscountRate float64 `json:"effective_discount_rate"` // 相對小計,可正可負
}
