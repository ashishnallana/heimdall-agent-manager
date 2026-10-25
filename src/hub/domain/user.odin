package domain

User_Status :: enum {
	Active,
	Disabled,
}

User :: struct {
	user_id:       User_ID,
	name:          string,
	display_name:   string,
	email:          string,
	status:         User_Status,
	created_at:     string,
	updated_at:     string,
}

