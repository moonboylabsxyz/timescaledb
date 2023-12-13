/*
 * This file and its contents are licensed under the Timescale License.
 * Please see the included NOTICE for copyright information and
 * LICENSE-TIMESCALE for a copy of the license.
 */
#ifndef TIMESCALEDB_TSL_COMPRESSIONAM_HANDLER_H
#define TIMESCALEDB_TSL_COMPRESSIONAM_HANDLER_H

#include <postgres.h>
#include <access/tableam.h>
#include <access/xact.h>
#include <fmgr.h>
#include <nodes/pathnodes.h>

#include "hypertable.h"

extern const TableAmRoutine *compressionam_routine(void);
extern void compressionam_set_rel_pathlist(PlannerInfo *root, RelOptInfo *rel, Hypertable *ht);
extern void compressionam_alter_access_method_begin(Oid relid, bool to_other_am);
extern void compressionam_alter_access_method_finish(Oid relid, bool to_other_am);
extern Datum compressionam_handler(PG_FUNCTION_ARGS);
extern void compressionam_xact_event(XactEvent event, void *arg);

#endif /* TIMESCALEDB_TSL_COMPRESSIONAM_HANDLER_H */
