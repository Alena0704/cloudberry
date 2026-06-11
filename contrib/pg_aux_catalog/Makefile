# contrib/pg_aux_catalog/Makefile

MODULE_big = pg_aux_catalog
OBJS = \
	$(WIN32RES) \
	pg_aux_catalog.o

EXTENSION = pg_aux_catalog
DATA = pg_aux_catalog--1.0.sql

PGFILEDESC = "pg_aux_catalog - auxiliary catalog management"

REGRESS = pg_aux_catalog
REGRESS_OPTS = --init-file=$(top_srcdir)/src/test/regress/init_file

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_aux_catalog
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
