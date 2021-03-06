
# Monthly_Report_Calcs.R

library(yaml)

if (Sys.info()["sysname"] == "Windows") {
    working_directory <- file.path(dirname(path.expand("~")), "Code", "AGENCY", "Flexdashboard-Report")
    
} else if (Sys.info()["sysname"] == "Linux") {
    working_directory <- file.path("~", "Code", "AGENCY", "Flexdashboard-Report")
    
} else {
    stop("Unknown operating system.")
}
setwd(working_directory)

source("Monthly_Report_Functions.R")
conf <- read_yaml("Monthly_Report_calcs.yaml")

#----- DEFINE DATE RANGE FOR CALCULATIONS ------------------------------------#
start_date <- ifelse(conf$start_date == "yesterday", 
                     format(today() - days(1), "%Y-%m-%d"),
                     conf$start_date)
end_date <- ifelse(conf$end_date == "yesterday",
                   format(today() - days(1), "%Y-%m-%d"),
                   conf$end_date)

# Manual overrides
#start_date <- "2018-10-31"
#end_date <- "2018-11-02"

month_abbrs <- get_month_abbrs(start_date, end_date)
#-----------------------------------------------------------------------------#

# # GET CORRIDORS #############################################################

# -- Code to update corridors file/table from Excel file

# corridors <- get_corridors(conf$corridors_xlsx_filename)
# write_feather(corridors, "corridors.feather")

conn <- get_atspm_connection()

# -- ----------------------------------------------------

corridors <- feather::read_feather(conf$corridors_filename) 

#signals_list <- corridors$SignalID[!is.na(corridors$SignalID)]
# -- If we want to run calcs on all signals in ATSPM database
sig_df <- dbReadTable(conn, "Signals") %>% 
    as_tibble() %>% 
    mutate(SignalID = factor(SignalID))
signals_list <- filter(sig_df, SignalID != "null")$SignalID

dbDisconnect(conn)

# -- TMC Codes for Corridors
#tmc_routes <- get_tmc_routes()
#write_feather(tmc_routes, "tmc_routes.feather")

# And one pass through the database to get all counts and comm uptime
print(Sys.time())
print("\ncounts\n")

get_counts2_date_range <- function(start_date, end_date) {
    
    start_dates <- seq(ymd(start_date), ymd(end_date), by = "1 day")
    
    lapply(start_dates, function(x) get_counts2(x, uptime = TRUE, counts = TRUE)) # counts = TRUE
}
get_counts2_date_range(start_date, end_date)

print("\n---------------------- Finished counts ---------------------------\n")

# combine daily (cu_yyyy-mm-dd.fst) into monthly (cu_yyyy-mm.fst)
lapply(month_abbrs, function(month_abbr) {
    
    ma <- ymd_hms(paste(month_abbr, 1, "00:00:00"))
    #date_hours <- seq(min(ma), max(ma) + months(1) - days(1), by = "1 day")
    
    
    fns <- list.files(pattern = paste0("cu_", month_abbr, "-\\d{2}.fst"))
    if (length(fns) > 0) {
        df <- lapply(fns, read_fst) %>%
            bind_rows()
        df %>% 
            complete(SignalID = signals_list, 
                     CallPhase, 
                     Date_Hour = seq(min(ma), max(df$Date_Hour), by = "1 day"), 
                     fill = list(uptime = 0)) %>%
            mutate(Date = date(Date_Hour),
                   DOW = lubridate::wday(Date),
                   Week = week(Date)) %>% 
            
            # filter out days before the signal came online
            left_join(select(corridors, SignalID, Asof)) %>% 
            filter(Date >= Asof) %>%
            select(-Asof) %>%
            
            write_fst(., paste0("cu_", month_abbr, ".fst"))
    }
})


# --- Everything up to here needs the ATSPM Database ---

signals_list <- corridors$SignalID[!is.na(corridors$SignalID)]

print(paste("Signals List", signals_list))
print(paste("Month Abbrs", month_abbrs))

# Group into months to calculate filtered and adjusted counts
# adjusted counts needs a full month to fill in gaps based on monthly averages


# Read Raw Counts for a month from files and output:
#   filtered_counts_1hr
#   adjusted_counts_1hr
#   BadDetectors

get_counts_based_measures <- function(month_abbrs) {
    lapply(month_abbrs, function(yyyy_mm) {
        
        gc()
        
        #-----------------------------------------------
        # 1-hour counts, filtered, adjusted, bad detectors
        
        month_pattern <- paste0("counts_1hr_", yyyy_mm, "-\\d\\d?\\.fst")
        fns <- list.files(pattern = month_pattern)
        
        print(fns)
        
        if (length(fns) > 0) {
            print("filtered counts")
            
            cl <- makeCluster(4)
            clusterExport(cl, c("get_filtered_counts",
                                "week",
                                "signals_list"))
            fcs <- parLapply(cl, fns, function(fn) {
                library(fst)
                library(dplyr)
                library(tidyr)
                library(lubridate)
                library(glue)
                library(feather)
                
                read_fst(fn) %>% 
                    filter(SignalID %in% signals_list) %>%
                    get_filtered_counts(., interval = "1 hour")
                
            })
            stopCluster(cl)
            
            filtered_counts_1hr <- bind_rows(fcs)
            write_fst_(filtered_counts_1hr, paste0("filtered_counts_1hr_", yyyy_mm, ".fst"))
            rm(fcs)
            
            print("adjusted counts")
            adjusted_counts_1hr <- get_adjusted_counts(filtered_counts_1hr)
            write_fst_(adjusted_counts_1hr, paste0("adjusted_counts_1hr_", yyyy_mm, ".fst"))

            print("bad detectors")
            bad_detectors <- get_bad_detectors(filtered_counts_1hr)

            bd_fn <- glue("bad_detectors_{yyyy_mm}.fst")
            write_fst(bad_detectors, bd_fn)
            
            aws.s3::put_object(file = bd_fn, 
                               object = glue("bad_detectors/{bd_fn}"), 
                               bucket = SPM_BUCKET)
            
            
            # VPD
            print("vpd")
            vpd <- get_vpd(adjusted_counts_1hr) # calculate over current period
            write_fst(vpd, paste0("vpd_", yyyy_mm, ".fst"))
            
            
            # VPH
            print("vph")
            vph <- get_vph(adjusted_counts_1hr)
            write_fst(vph, paste0("vph_", yyyy_mm, ".fst"))
            
            
            # DAILY DETECTOR UPTIME
            print("ddu")
            daily_detector_uptime <- get_daily_detector_uptime(filtered_counts_1hr)
            ddu <- bind_rows(daily_detector_uptime)
            write_fst_(ddu, paste0("ddu_", yyyy_mm, ".fst"))
            
        }
        
        
        
        
        
        #-----------------------------------------------
        # 15-minute counts and throughput
        print("15-minute counts and throughput")
        month_pattern <- paste0("counts_15min_TWR_", yyyy_mm, "-\\d\\d?\\.fst")
        fns <- list.files(pattern = month_pattern)
        
        if (length(fns) > 0) {
            
            print(fns)
            
            print("15-min filtered counts")
            
            cl <- makeCluster(4)
            clusterExport(cl, c("get_filtered_counts",
                                "week",
                                "signals_list",
                                "bad_detectors"),
                          envir = environment())
            fcs <- parLapply(cl, fns, function(fn) {
                library(fst)
                library(dplyr)
                library(tidyr)
                library(lubridate)
                
                # Filter and Adjust (interpolate) 15 min Counts
                df <- read_fst(fn) %>%
                    as_tibble() %>%
                    filter(SignalID %in% signals_list) %>%
                    mutate(Date = date(Timeperiod))
                
                bd <- bad_detectors %>%
                    filter(Date %in% unique(df$Date))
                
                anti_join(df, bd)
                
            })
            stopCluster(cl)
            
            filtered_counts_15min <- bind_rows(fcs) %>%
                mutate(Month_Hour = Timeperiod - days(day(Timeperiod) - 1))
            rm(fcs)
            
            print("adjusted counts")
            adjusted_counts_15min <- get_adjusted_counts(filtered_counts_15min) %>%
                mutate(Date = date(Timeperiod))
            rm(filtered_counts_15min)
            
            # Calculate and write Throughput
            print("throughput")
            throughput <- get_thruput(adjusted_counts_15min)
            rm(adjusted_counts_15min)
            
            write_fst(throughput, paste0("tp_", yyyy_mm, ".fst"))
        }
    })
}
get_counts_based_measures(month_abbrs)

bd_fns <- list.files(pattern = "bad_detectors.*\\.fst")
lapply(bd_fns, read_fst) %>% bind_rows() %>% 
    select(-Good_Day) %>%
    write_feather("bad_detectors.feather")

print("--- Finished counts-based measures ---")


# -- Run etl_dashboard (Python): cycledata, detectionevents to S3/Athena --
import_from_path("spm_events")
py_run_file("etl_dashboard.py") # python script

# --- ----------------------------- -----------


# # GET ARRIVALS ON GREEN #####################################################
get_aog_date_range <- function(start_date, end_date) {

    start_dates <- seq(ymd(start_date), ymd(end_date), by = "1 month")
    cl <- makeCluster(4)
    clusterExport(cl, c("get_cycle_data",
                        "get_spm_data",
                        "get_spm_data_aws",
                        "write_fst_",
                        "get_aog",
                        "signals_list",
                        "end_date",
                        "week"))
    parLapply(cl, start_dates, function(start_date) {
        library(DBI)
        library(RJDBC)
        library(dplyr)
        library(tidyr)
        library(lubridate)
        library(glue)
        library(purrr)
        library(fst)

        
        start_date <- floor_date(start_date, "months")
        end_date <- start_date + months(1) - days(1)

        cycle_data <- get_cycle_data(start_date, end_date, signals_list)
        if (nrow(collect(head(cycle_data))) > 0) {
            aog <- get_aog(cycle_data)
            yyyy_mm <- format(ymd(start_date), "%Y-%m")
            write_fst_(aog, glue("aog_{yyyy_mm}.fst"), append = FALSE)

        }
    })
    stopCluster(cl)
}
print("aog")
get_aog_date_range(start_date, end_date)


# # GET QUEUE SPILLBACK #######################################################
get_queue_spillback_date_range <- function(start_date, end_date) {

    start_dates <- seq(ymd(start_date), ymd(end_date), by = "1 month")
    cl <- makeCluster(4)
    clusterExport(cl, c("glue",
                        "read_feather",
                        "get_detection_events",
                        "get_spm_data",
                        "get_spm_data_aws",
                        "write_fst_",
                        "get_qs",
                        "signals_list",
                        "end_date",
                        "week"))
    parLapply(cl, start_dates, function(start_date) {
        library(DBI)
        library(RJDBC)
        library(dplyr)
        library(tidyr)
        library(lubridate)
        library(fst)

        start_date <- floor_date(start_date, "months")
        end_date <- start_date + months(1) - days(1)

        detection_events <- get_detection_events(start_date, end_date, signals_list)
        if (nrow(collect(head(detection_events))) > 0) {
            qs <- get_qs(detection_events)
            write_fst_(qs, paste0("qs_", substr(ymd(start_date), 1, 7), ".fst"), append = FALSE)
        }
    })
    stopCluster(cl)
}
print("queue spillback")
get_queue_spillback_date_range(start_date, end_date)



# # GET SPLIT FAILURES ########################################################

print("split failures")
py_run_file("split_failures2.py") # python script

lapply(month_abbrs, function(month_abbr) {
    fns <- list.files(pattern = paste0("sf_", month_abbr, "-\\d{2}.feather"))
    
    wds <- lubridate::wday(sub(pattern = "sf_(.*)\\.feather", "\\1", fns), label = TRUE)
    twr <- sapply(wds, function(x) {x %in% c("Tue", "Wed", "Thu")})
    fns <- fns[twr]
    
    print(fns)
    if (length(fns) > 0) {
        lapply(fns, read_feather) %>%
            bind_rows() %>% 
            transmute(SignalID = factor(SignalID),
                      CallPhase = factor(Phase),
                      Date = date(Hour),
                      Date_Hour = Hour,
                      DOW = wday(Hour),
                      Week = week(Date),
                      sf = sf,
                      cycles = cycles,
                      sf_freq = sf_freq) %>%
            write_fst(., paste0("sf_", month_abbr, ".fst"))
    }
})


# # TRAVEL TIMES FROM RITIS API ###############################################

#py_run_file("get_travel_times.py") # Run python script

print("\n--------------------- End Monthly Report calcs -----------------------\n")
