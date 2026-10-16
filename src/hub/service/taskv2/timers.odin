package taskv2

// Timer_Service{clock, heap, fire_due(now)} — M1. Columns are the truth; the
// heap is a cache rebuilt on boot.
Timer_Service :: struct {
	armed: int,
}
