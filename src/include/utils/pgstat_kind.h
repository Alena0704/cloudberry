/* -------------------------------------------------------------------------
 *
 * pgstat_kind.h
 *	  Compatibility shim for extensions written against PG18+.
 *
 * Upstream PG18 (commit f98dbdeb51) split the PgStat_Kind enum and custom-kind
 * registration API out of pgstat.h into utils/pgstat_kind.h. Cloudberry's PG16
 * base keeps everything in pgstat.h; this shim re-exports the relevant
 * declarations so extensions can include this header verbatim.
 *
 * src/include/utils/pgstat_kind.h
 * -------------------------------------------------------------------------
 */
#ifndef PGSTAT_KIND_H
#define PGSTAT_KIND_H

#include "pgstat.h"

#endif							/* PGSTAT_KIND_H */
