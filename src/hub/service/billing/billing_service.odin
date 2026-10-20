package billing

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import device_auth "odin_test:hub/service/device_auth"
import http_client "odin_test:lib/http_client"

Config :: struct {
	environment: string,
	api_key: string,
	client_token: string,
	webhook_secret: string,
	past_due_grace_seconds: int,
}
Service :: struct {
	repo: ^iface.Billing_Repository,
	clock: ^platform.Clock,
	config: Config,
	request: proc(config: Config, method, path, body: string) -> (string, domain.Domain_Error),
	// Optional seams; nil keeps production behavior (global metrics, OS CSPRNG).
	metrics: ^Billing_Metrics,
	new_reference: proc() -> (string, bool),
}
Offer :: struct {
	offer_id: string,
	plan_label: string,
	entitlements: domain.User_Entitlements,
}
Account_View :: struct {
	user_id: string,
	plan_label: string,
	subscription_plan_label: string,
	status: string,
	entitlements: domain.User_Entitlements,
	offers: []Offer,
	checkout_enabled: bool,
	manage_subscription_enabled: bool,
	checkout_pending: bool,
	renews_at: string,
	cancels_at: string,
	grace_until: string,
	environment: string,
	client_token: string,
}
Checkout_Result :: struct { transaction_id: string, checkout_url: string }
Portal_Result :: struct { url: string }

is_configured :: proc(config: Config) -> bool {
	return config.api_key != "" && config.client_token != "" && config.webhook_secret != "" && (config.environment == "sandbox" || config.environment == "live")
}

account_view :: proc(service: ^Service, user_id: string) -> (Account_View, domain.Domain_Error) {
	now := platform.clock_now(service.clock)
	account, err := service.repo.get_account(service.repo.ctx, user_id, now)
	if err.code != .None do return {}, err
	plans, plan_err := service.repo.list_plans(service.repo.ctx)
	if plan_err.code != .None do return {}, plan_err
	label := account.plan_label
	entitled := account.status == "active" || account.status == "trialing" || account.status == "custom" || (account.status == "past_due" && account.grace_until > now)
	if !entitled {
		for plan in plans { if plan.plan_id == "free" do label = plan.plan_label }
	}
	offers := make([dynamic]Offer, context.temp_allocator)
	can_purchase := account.subscription_id == "" || account.status == "canceled"
	if account.status == "custom" do can_purchase = false
	if can_purchase {
		for plan in plans {
			if plan.price_id != "" && plan.plan_id != "free" {
				append(&offers, Offer{offer_id = plan.plan_id, plan_label = plan.plan_label, entitlements = plan.entitlements})
			}
		}
	}
	return Account_View{user_id = user_id, plan_label = label, subscription_plan_label = account.plan_label, status = account.status,
		entitlements = account.entitlements, offers = offers[:], checkout_enabled = is_configured(service.config),
		manage_subscription_enabled = service.config.api_key != "" && account.customer_id != "", renews_at = account.renews_at,
		cancels_at = account.cancels_at, grace_until = account.grace_until, environment = service.config.environment,
		client_token = service.config.client_token, checkout_pending = account.checkout_pending}, {}
}

start_checkout :: proc(service: ^Service, user_id, offer_id: string) -> (Checkout_Result, domain.Domain_Error) {
	if !is_configured(service.config) do return {}, domain.domain_error(.Not_Implemented, "billing checkout is not configured yet")
	account, err := service.repo.get_account(service.repo.ctx, user_id, platform.clock_now(service.clock))
	if err.code != .None do return {}, err
	if account.status == "custom" || (account.subscription_id != "" && account.status != "canceled") do return {}, domain.domain_error(.Conflict, "manage your existing subscription instead of starting another checkout")
	plans, plan_err := service.repo.list_plans(service.repo.ctx)
	if plan_err.code != .None do return {}, plan_err
	selected: domain.Billing_Plan
	for plan in plans { if plan.plan_id == offer_id && plan.plan_id != "free" && plan.price_id != "" do selected = plan }
	if selected.price_id == "" do return {}, domain.domain_error(.Validation_Failed, "this subscription offer is not available")
	generate := service.new_reference
	if generate == nil do generate = device_auth.generate_device_code
	reference, random_ok := generate()
	if !random_ok do return {}, domain.domain_error(.Internal_Error, "could not prepare checkout reference")
	now := platform.clock_now(service.clock)
	parsed_now, _ := platform.parse_rfc3339_utc(now)
	checkout, reserved, reserve_err := service.repo.reserve_checkout(service.repo.ctx, domain.Billing_Checkout{reference = reference, user_id = user_id, plan_id = selected.plan_id, price_id = selected.price_id, expires_at = platform.format_rfc3339_utc(time.time_add(parsed_now, 20*time.Minute))}, now)
	if reserve_err.code != .None do return {}, reserve_err
	if !reserved {
		// Reuse the reserved transaction rather than creating a duplicate, but
		// fetch its checkout URL so retries return the same complete contract.
		if !valid_transaction_id(checkout.transaction_id) do return {}, domain.domain_error(.Conflict, "a checkout is already being prepared; retry shortly")
		body, api_err := paddle_request(service, "GET", fmt.tprintf("/transactions/%s", checkout.transaction_id), "")
		if api_err.code != .None do return {}, api_err
		return checkout_result(body, checkout.transaction_id)
	}
	payload := struct {
		items: [1]struct {price_id: string, quantity: int},
		collection_mode: string,
		customer_id: string `json:"customer_id,omitempty"`,
		custom_data: struct {heimdall_checkout_reference: string},
	}{items = {{price_id = selected.price_id, quantity = 1}}, collection_mode = "automatic", customer_id = account.customer_id, custom_data = {heimdall_checkout_reference = checkout.reference}}
	encoded, encode_err := json.marshal(payload, allocator = context.temp_allocator)
	if encode_err != nil do return {}, domain.domain_error(.Internal_Error, "could not encode checkout")
	body, api_err := paddle_request(service, "POST", "/transactions", string(encoded))
	// Keep failed/ambiguous reservations for 20 minutes: retrying immediately
	// could duplicate a transaction Paddle created before a connection failed.
	if api_err.code != .None do return {}, api_err
	response: struct {data: struct {id: string}}
	if json.unmarshal_string(body, &response, .JSON, context.temp_allocator) != nil || !valid_transaction_id(response.data.id) do return {}, domain.domain_error(.Internal_Error, "Paddle returned an invalid checkout response")
	// Persist the transaction before validating its URL so a retry reuses it
	// instead of creating a duplicate.
	checkout.transaction_id = response.data.id
	save_err := service.repo.finish_checkout(service.repo.ctx, checkout)
	if save_err.code != .None do return {}, save_err
	return checkout_result(body, checkout.transaction_id)
}

checkout_result :: proc(body, transaction_id: string) -> (Checkout_Result, domain.Domain_Error) {
	response: struct {data: struct {id: string, checkout: struct {url: string}}}
	if json.unmarshal_string(body, &response, .JSON, context.temp_allocator) != nil || response.data.id != transaction_id do return {}, domain.domain_error(.Internal_Error, "Paddle returned an invalid checkout response")
	if !valid_checkout_url(response.data.checkout.url, transaction_id) do return {}, domain.domain_error(.Internal_Error, "Paddle returned an invalid checkout URL")
	return Checkout_Result{transaction_id = transaction_id, checkout_url = response.data.checkout.url}, {}
}

valid_transaction_id :: proc(id: string) -> bool {
	if !strings.has_prefix(id, "txn_") || len(id) == len("txn_") do return false
	for c in id[len("txn_"):] { if !(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') do return false }
	return true
}

// Paddle's checkout URL is the account's approved payment link plus
// ?_ptxn=<transaction>. The browser is redirected there, so accept only HTTPS
// without credentials and bound to exactly this transaction.
valid_checkout_url :: proc(url, transaction_id: string) -> bool {
	if !valid_transaction_id(transaction_id) || !strings.has_prefix(url, "https://") do return false
	for c in url { if c <= ' ' || c >= 0x7f || c == '\\' do return false }
	rest := url[len("https://"):]
	authority_end := strings.index_any(rest, "/?#")
	if authority_end < 0 do return false
	authority := rest[:authority_end]
	host, has_port, port := strings.partition(authority, ":")
	if host == "" || (has_port != "" && port == "") do return false
	for c in host { if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != '.' && c != '-' do return false }
	for c in port { if c < '0' || c > '9' do return false }
	target, _, _ := strings.partition(rest[authority_end:], "#")
	_, _, query := strings.partition(target, "?")
	matches := 0
	for pair in strings.split_iterator(&query, "&") {
		key, _, value := strings.partition(pair, "=")
		if key != "_ptxn" do continue
		if value != transaction_id do return false
		matches += 1
	}
	return matches == 1
}

create_portal :: proc(service: ^Service, user_id: string) -> (Portal_Result, domain.Domain_Error) {
	if service.config.api_key == "" do return {}, domain.domain_error(.Not_Implemented, "subscription management is not configured yet")
	account, err := service.repo.get_account(service.repo.ctx, user_id, platform.clock_now(service.clock))
	if err.code != .None do return {}, err
	if !strings.has_prefix(account.customer_id, "ctm_") do return {}, domain.domain_error(.Not_Found, "account has no billing customer")
	body, api_err := paddle_request(service, "POST", fmt.tprintf("/customers/%s/portal-sessions", account.customer_id), "{}")
	if api_err.code != .None do return {}, api_err
	response: struct {data: struct {urls: struct {general: struct {overview: string}}}}
	if json.unmarshal_string(body, &response, .JSON, context.temp_allocator) != nil do return {}, domain.domain_error(.Internal_Error, "Paddle returned an invalid portal response")
	url := response.data.urls.general.overview
	if !strings.has_prefix(url, "https://customer-portal.paddle.com/") && !strings.has_prefix(url, "https://sandbox-customer-portal.paddle.com/") do return {}, domain.domain_error(.Internal_Error, "Paddle returned an invalid portal URL")
	return Portal_Result{url = url}, {}
}

paddle_request :: proc(service: ^Service, method, path, body: string) -> (string, domain.Domain_Error) {
	request := service.request
	if request == nil do request = request_paddle_api
	return request(service.config, method, path, body)
}

request_paddle_api :: proc(config: Config, method, path, body: string) -> (string, domain.Domain_Error) {
	base := "https://sandbox-api.paddle.com" if config.environment == "sandbox" else "https://api.paddle.com"
	headers := []http_client.Header{{name = "Authorization", value = fmt.tprintf("Bearer %s", config.api_key)}}
	response, ok := http_client.request_with_headers_timeout(method, base, path, body, headers, 15000, true)
	if !ok do return "", domain.domain_error(.Internal_Error, "could not contact Paddle; retry later")
	if response.status < 200 || response.status >= 300 do return "", domain.domain_error(.Internal_Error, "Paddle could not complete this request; check billing configuration")
	return response.body, {}
}
