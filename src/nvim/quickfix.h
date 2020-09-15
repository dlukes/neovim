#ifndef NVIM_QUICKFIX_H
#define NVIM_QUICKFIX_H

#include <pthread.h>

#include "nvim/types.h"
#include "nvim/ex_cmds_defs.h"

/* flags for skip_vimgrep_pat() */
#define VGR_GLOBAL      1
#define VGR_NOJUMP      2

#ifdef INCLUDE_GENERATED_DECLARATIONS
# include "quickfix.h.generated.h"
#endif
#endif  // NVIM_QUICKFIX_H

extern pthread_mutex_t qf_lock;
