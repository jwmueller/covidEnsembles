library(gurobi)
library(quantgen)
library(covidData)
library(covidEnsembles)
library(tidyverse)
library(zeallot)
library(gridExtra)
library(yaml)

#options(warn=2, error=recover)

#debug(covidEnsembles:::get_by_location_group_ensemble_fits_and_predictions)
#debug(covidEnsembles:::estimate_qra_quantgen)

# extract arguments specifying details of analysis
#args <- c("cum_death", "2020-05-09", "FALSE", "convex", "by_location_group", "3_groups", "2")
#args <- c("cum_death", "2020-05-09", "TRUE", "positive", "by_location_group", "3_groups", "2")
#args <- c("cum_death", "2020-05-09", "TRUE", "positive", "mean_impute", "3_groups", "2")
#args <- c("cum_death", "2020-05-16", "FALSE", "convex", "mean_impute", "per_model", "3")
#args <- c("cum_death", "2020-06-06", "FALSE", "convex", "mean_impute", "per_model", "6", "TRUE")
#args <- c("cum_death", "2020-06-13", "FALSE", "convex", "by_location_group", "per_quantile", "4", "TRUE")
#args <- c("cum_death", "2020-06-13", "FALSE", "convex", "by_location_group", "per_quantile", "4", "TRUE", "TRUE")
#args <- c("inc_death", "2020-05-23", "TRUE", "positive", "mean_impute", "3_groups", "3", "FALSE", "TRUE")
#args <- c("inc_death", "2020-07-25", "TRUE", "positive", "mean_impute", "per_quantile", "5", "TRUE", "FALSE")
#args <- c("cum_death", "2020-05-16", "FALSE", "convex", "by_location_group", "per_quantile", "5", "FALSE", "FALSE")
#args <- c("inc_death", "2020-07-25", "TRUE", "positive", "mean_impute", "3_groups", "3", "TRUE", "FALSE", "FALSE")
#args <- c("cum_death", "2020-05-09", "FALSE", "convex", "mean_impute", "3_groups", "2", "FALSE", "TRUE", "FALSE")
#args <- c("cum_death", "2020-08-01", "FALSE", "ew", "by_location_group", "per_model", "0", "FALSE", "FALSE", "FALSE")
#args <- c("inc_case", "2020-08-01", "FALSE", "convex", "by_location_group", "per_quantile", "2", "FALSE", "TRUE", "FALSE")
#args <- c("inc_case", "2020-10-24", "TRUE", "positive", "mean_impute", "3_groups", "4", "FALSE", "FALSE", "FALSE")
#args <- c("inc_case", "2020-05-09", "FALSE", "ew", "by_location_group", "per_model", "0", "FALSE", "FALSE", "FALSE")
#args <- c("inc_case", "2020-06-27", "FALSE", "ew", "by_location_group", "per_model", "0", "FALSE", "FALSE", "FALSE", "national")
#args <- c("inc_death", "2020-11-30", "FALSE", "median", "by_location_group", "per_model", "0", "FALSE", "FALSE", "FALSE", "state")
#args <- c("inc_hosp", "2020-11-16", "FALSE", "convex", "mean_impute", "per_model", "3", "FALSE", "FALSE", "FALSE", "state")
#args <- c("inc_death", "2020-11-30", "FALSE", "convex", "mean_impute", "per_quantile", "4", "FALSE", "FALSE", "FALSE", "state")
#args <- c("inc_death", "2020-05-18", "FALSE", "convex", "mean_impute", "per_model", "10", "TRUE", "FALSE", "FALSE", "state_national")

args <- commandArgs(trailingOnly = TRUE)
run_setting <- args[1]

if (run_setting == "local") {
  # running locally -- run settings passed as command line arguments
  response_var <- args[2]
  forecast_date <- lubridate::ymd(args[3])
  intercept <- as.logical(args[4])
  combine_method <- args[5]
  missingness <- args[6]
  quantile_group_str <- args[7]
  window_size_arg <- args[8]
  check_missingness_by_target <- as.logical(args[9])
  do_standard_checks <- as.logical(args[10])
  do_baseline_check <- as.logical(args[11])
  spatial_resolution_arg <- args[12]

  submissions_root <- "~/research/epi/covid/covid19-forecast-hub/data-processed/"
} else {
  # running on cluster -- extract run settings from csv file of analysis
  # combinations, row specified by job run index passed as command line
  # argument
  print("Args:")
  print(args)
  job_ind <- as.integer(Sys.getenv("SLURM_ARRAY_TASK_ID"))
  print(paste0("Job index: ", job_ind))

  analysis_combinations <- readr::read_csv(
    "code/application/retrospective-qra-comparison/analysis_combinations.csv"
  )
  
  response_var <- analysis_combinations$response_var[job_ind]
  forecast_date <- analysis_combinations$forecast_date[job_ind]
  intercept <- analysis_combinations$intercept[job_ind]
  combine_method <- analysis_combinations$combine_method[job_ind]
  missingness <- analysis_combinations$missingness[job_ind]
  quantile_group_str <- analysis_combinations$quantile_group_str[job_ind]
  window_size_arg <- analysis_combinations$window_size[job_ind]
  check_missingness_by_target <- analysis_combinations$check_missingness_by_target[job_ind]
  do_standard_checks <- analysis_combinations$do_standard_checks[job_ind]
  do_baseline_check <- analysis_combinations$do_baseline_check[job_ind]
  spatial_resolution_arg <- analysis_combinations$spatial_resolution[job_ind]

  submissions_root <- "~/covid19-forecast-hub/data-processed/"
}

# List of candidate models for inclusion in ensemble
candidate_model_abbreviations_to_include <- get_candidate_models(
  submissions_root = submissions_root,
  include_designations = c("primary", "secondary"),
  include_COVIDhub_ensemble = FALSE,
  include_COVIDhub_baseline = TRUE)

# Drop hospitalizations ensemble from JHU APL
candidate_model_abbreviations_to_include <-
  candidate_model_abbreviations_to_include[
    !(candidate_model_abbreviations_to_include == "JHUAPL-SLPHospEns")
  ]


if (missingness == "mean_impute") {
  missingness <- "impute"
  impute_method <- "mean"
} else {
  impute_method <- NULL
}

if (response_var %in% c("inc_death", "cum_death")) {
  required_quantiles <- c(0.01, 0.025, seq(0.05, 0.95, by = 0.05), 0.975, 0.99)
  if (spatial_resolution_arg == "all") {
    spatial_resolution <- c("state", "national")
  } else if (spatial_resolution_arg == "state_national") {
    spatial_resolution <- c("state", "national")
  } else {
    spatial_resolution <- spatial_resolution_arg
  }
  temporal_resolution <- "wk"
  horizon <- 4L
  targets <- paste0(1:horizon, " wk ahead ", gsub("_", " ", response_var))
  forecast_week_end_date <- forecast_date - 2
  full_history_start <- lubridate::ymd("2020-06-22") - 7 * 10
} else if (response_var == "inc_case") {
  required_quantiles <- c(0.025, 0.100, 0.250, 0.500, 0.750, 0.900, 0.975)
  if (spatial_resolution_arg == "all") {
    spatial_resolution <- c("county", "state", "national")
  } else if (spatial_resolution_arg == "state_national") {
    spatial_resolution <- c("state", "national")
  } else {
    spatial_resolution <- spatial_resolution_arg
  }
  temporal_resolution <- "wk"
  horizon <- 4L
  targets <- paste0(1:horizon, " wk ahead ", gsub("_", " ", response_var))
  forecast_week_end_date <- forecast_date - 2
  full_history_start <- lubridate::ymd("2020-09-14") - 7 * 10
} else if (response_var == "inc_hosp") {
  required_quantiles <- c(0.01, 0.025, seq(0.05, 0.95, by = 0.05), 0.975, 0.99)
  if (spatial_resolution_arg == "all") {
    spatial_resolution <- c("state", "national")
  } else if (spatial_resolution_arg == "state_national") {
    spatial_resolution <- c("state", "national")
  } else {
    spatial_resolution <- spatial_resolution_arg
  }
  temporal_resolution <- "day"
  horizon <- 28L
  targets <- paste0(1:(horizon + 6), " day ahead ", gsub("_", " ", response_var))
  forecast_week_end_date <- forecast_date
  full_history_start <- lubridate::ymd("2020-11-16") - 7 * 10
}

if (window_size_arg == "full_history") {
  window_size <- as.integer((forecast_date - full_history_start) / 7)
} else {
  window_size <- as.integer(window_size_arg)
}


if(quantile_group_str == "per_model") {
  quantile_groups <- rep(1, length(required_quantiles))
} else if(quantile_group_str == "3_groups") {
  if (length(required_quantiles) == 23) {
    quantile_groups <- c(rep(1, 4), rep(2, 23 - 8), rep(3, 4))
  } else if (length(required_quantiles) == 7) {
    quantile_groups <- c(1, rep(2, 5), 3)
  }
} else if(quantile_group_str == "per_quantile") {
  quantile_groups <- seq_along(required_quantiles)
} else {
  stop("invalid quantile_groups")
}

if (spatial_resolution_arg == "all") {
  spatial_resolution_path <- ""
} else if (spatial_resolution_arg == "state_national") {
  spatial_resolution_path <- "state_national"
} else {
  spatial_resolution_path <- spatial_resolution
}

case_str <- paste0(
  "intercept_", as.character(intercept),
  "-combine_method_", combine_method,
  "-missingness_", missingness,
  "-quantile_groups_", quantile_group_str,
  "-window_size_", window_size_arg,
  "-check_missingness_by_target_", check_missingness_by_target,
  "-do_standard_checks_", do_standard_checks,
  "-do_baseline_check_", do_baseline_check)

# create folder where model fits should be saved
fits_dir <- file.path(
  "code/application/retrospective-qra-comparison/retrospective-fits",
  spatial_resolution_path,
  case_str)
if (!dir.exists(fits_dir)) {
  dir.create(fits_dir)
}
fit_filename <- paste0(
  fits_dir, "/",
  response_var, "-", forecast_date, "-",
  case_str, ".rds")

# create folder where model weights should be saved
weights_dir <- file.path(
  "code/application/retrospective-qra-comparison/retrospective-weights",
  spatial_resolution_path,
  case_str)
if (!dir.exists(weights_dir)) {
  dir.create(weights_dir)
}
weight_filename <- paste0(
  weights_dir, "/",
  response_var, "-", forecast_date, "-",
  case_str, ".csv")

# create folder where model forecasts should be saved
forecasts_dir <- file.path(
  "code/application/retrospective-qra-comparison/retrospective-forecasts",
  spatial_resolution_path,
  case_str)
if (!dir.exists(forecasts_dir)) {
  dir.create(forecasts_dir)
}
forecast_filename <- paste0(
  forecasts_dir, "/",
  response_var, "-", forecast_date, "-",
  case_str, ".csv")


tic <- Sys.time()
if(!file.exists(forecast_filename)) {
  do_q10_check <- do_nondecreasing_quantile_check <- do_standard_checks

  results <- build_covid_ensemble_from_local_files(
    candidate_model_abbreviations_to_include =
      candidate_model_abbreviations_to_include,
    spatial_resolution = spatial_resolution,
    targets = targets,
    forecast_date = forecast_date,
    forecast_week_end_date = forecast_week_end_date,
    horizon = horizon,
    timezero_window_size = 6,
    window_size = window_size,
    intercept = intercept,
    combine_method = combine_method,
    quantile_groups = quantile_groups,
    missingness = missingness,
    impute_method = impute_method,
    backend = "quantgen",
    submissions_root = submissions_root,
    required_quantiles = required_quantiles,
    check_missingness_by_target = check_missingness_by_target,
    do_q10_check = do_q10_check,
    do_nondecreasing_quantile_check = do_nondecreasing_quantile_check,
    do_baseline_check = do_baseline_check,
    baseline_tol = 1.0,
    manual_eligibility_adjust = NULL,
    return_eligibility = TRUE,
    return_all = TRUE
  )

  # save full results including estimated weights, training data, etc.
  # only if running locally; cluster has limited space
  if (run_setting == "local") {
    saveRDS(results, file = fit_filename)
  }

  # extract and save just the estimated weights in csv format
  if (!(combine_method %in% c("ew", "mean", "median"))) {
    estimated_weights <- purrr::pmap_dfr(
      results$location_groups %>% dplyr::select(locations, qra_fit),
      function(locations, qra_fit) {
        weights <- qra_fit$coefficients

        data.frame(
          quantile = if ("quantile" %in% colnames(weights)) {
              weights$quantile
            } else {
              rep(NA, nrow(weights))
            },
          model = weights$model,
          weight = weights$beta, #[, 1],
          join_field = "temp",
          stringsAsFactors = FALSE
        ) %>%
          dplyr::left_join(
            data.frame(
              location = locations,
              join_field = "temp",
              stringsAsFactors = FALSE
            )
          ) %>%
          dplyr::select(-join_field)
      }
    )
    write_csv(estimated_weights, weight_filename)
  }


  # save csv formatted forecasts
  if (missingness == "impute") {
    c(model_eligibility, wide_model_eligibility, location_groups,
      weight_transfer, component_forecasts) %<-% results
    
    col_index <- attr(location_groups$qfm_test[[1]], "col_index")
    models_used <- purrr::map_dfc(
      unique(col_index$model),
      function(model) {
        col_ind <- min(which(col_index$model == model))
        result <- data.frame(
          m = !is.na(unclass(location_groups$qfm_test[[1]])[, col_ind]))
        colnames(result) <- model
        return(result)
      }
    )
    model_counts <- apply(
      models_used,
      1,
      sum
    )

    locations_to_drop <- unique(
      attr(location_groups$qfm_test[[1]], "row_index")[
        model_counts == 1, "location"])
    
    ensemble_predictions <- location_groups$qra_forecast[[1]] %>%
      dplyr::filter(!(location %in% locations_to_drop))
  } else {
    c(model_eligibility, wide_model_eligibility, location_groups,
      component_forecasts) %<-% results
    
    model_counts <- apply(
      location_groups %>% select_if(is.logical),
      1,
      sum)
    location_groups <- location_groups[model_counts > 1, ]

    if (nrow(location_groups) > 0) {
      ensemble_predictions <- bind_rows(location_groups[['qra_forecast']])
    }
  }

  if (nrow(ensemble_predictions) > 0) {
    # save the results in required format
    formatted_ensemble_predictions <- ensemble_predictions %>%
      dplyr::transmute(
        forecast_date = forecast_date,
        target = target,
        target_end_date = covidHubUtils::calc_target_end_date(
          forecast_date,
          as.integer(substr(target, 1, regexpr(" ", target, fixed = TRUE) - 1)),
          rep(temporal_resolution, nrow(ensemble_predictions))),
        location = location,
        type = 'quantile',
        quantile = quantile,
        value = ifelse(
          quantile < 0.5,
          floor(value),
          ifelse(
            quantile == 0.5,
            round(value),
            ceiling(value)
          )
        )
      )

    formatted_ensemble_predictions <- bind_rows(
      formatted_ensemble_predictions,
      formatted_ensemble_predictions %>%
        filter(format(quantile, digits = 3, nsmall = 3) == "0.500") %>%
        mutate(
          type = "point",
          quantile = NA_real_
        )
    )
    
    write_csv(formatted_ensemble_predictions, forecast_filename)
  }
}
toc <- Sys.time()
toc - tic
