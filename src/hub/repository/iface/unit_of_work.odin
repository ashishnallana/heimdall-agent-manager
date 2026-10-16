package iface

import domain "odin_test:hub/domain"

Unit_Of_Work_Commit_Proc :: proc(ctx: rawptr) -> (bool, domain.Domain_Error)
Unit_Of_Work_Rollback_Proc :: proc(ctx: rawptr)
Unit_Of_Work_Begin_Proc :: proc(ctx: rawptr) -> (Unit_Of_Work, bool, domain.Domain_Error)

// After_Commit_Hook runs once the OUTERMOST transaction has committed and its
// lock is released. A nested (SAVEPOINT) unit of work registers its post-commit
// effects here instead of flushing them under the outer transaction.
After_Commit_Hook :: struct {
	ctx: rawptr,
	run: proc(ctx: rawptr),
}

Unit_Of_Work_After_Commit_Proc :: proc(ctx: rawptr, hook: After_Commit_Hook) -> bool

Unit_Of_Work :: struct {
	ctx: rawptr,
	commit: Unit_Of_Work_Commit_Proc,
	rollback: Unit_Of_Work_Rollback_Proc,
	repos: ^Repositories,
	// nested: this unit of work is a SAVEPOINT inside a transaction owned by
	// the same thread; its commit is not the real COMMIT.
	nested: bool,
	after_commit: Unit_Of_Work_After_Commit_Proc,
}

// unit_of_work_after_commit registers a hook to run after the outermost COMMIT
// (and after the transaction lock is released). Returns false when the
// implementation cannot defer (the caller then runs the effect itself).
unit_of_work_after_commit :: proc(uow: ^Unit_Of_Work, hook: After_Commit_Hook) -> bool {
	if uow == nil || uow.after_commit == nil do return false
	return uow.after_commit(uow.ctx, hook)
}

Unit_Of_Work_Factory :: struct {
	ctx: rawptr,
	begin: Unit_Of_Work_Begin_Proc,
}

unit_of_work_begin :: proc(factory: ^Unit_Of_Work_Factory) -> (Unit_Of_Work, bool, domain.Domain_Error) {
	if factory == nil || factory.begin == nil {
		return Unit_Of_Work{}, false, domain.domain_error(.Internal_Error, "unit of work factory is not configured")
	}
	return factory.begin(factory.ctx)
}

unit_of_work_commit :: proc(uow: ^Unit_Of_Work) -> (bool, domain.Domain_Error) {
	if uow == nil || uow.commit == nil {
		return false, domain.domain_error(.Internal_Error, "unit of work is not configured")
	}
	return uow.commit(uow.ctx)
}

unit_of_work_rollback :: proc(uow: ^Unit_Of_Work) {
	if uow == nil || uow.rollback == nil do return
	uow.rollback(uow.ctx)
}
