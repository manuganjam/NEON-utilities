##############################################################################################
#' @title Join data files in a unzipped NEON data package by table type

#' @author
#' Christine Laney \email{claney@battelleecology.org}

#' @description
#' Given a folder of unzipped files (unzipped NEON data file), do a full join of all data files, grouped by table type.
#' This should result in a small number of large files.

#' @param folder The location of the data
#' @param nCores The number of cores to parallelize the stacking procedure. By default it is set to a single core.
#' @param forceParallel If the data volume to be processed does not meet minimum requirements to run in parallel, this overrides. Set to FALSE as default.
#' @return One file for each table type is created and written.

#' @references
#' License: GNU AFFERO GENERAL PUBLIC LICENSE Version 3, 19 November 2007

# Changelog and author contributions / copyrights
#   2017-07-02 (Christine Laney): Original creation
#   2018-04-03 (Christine Laney):
#     * Swap read.csv() for data.table::fread() for faster data table loading
#     * Swap data.table::rbind() for dplyr::join() for faster table joins
#     * Remove join messages, replace with progress bars
#     * Provide comparison of number of rows expected per stacked table vs number of row in final table
#   2018-04-13 (Christine Laney):
#     * Continuous stream discharge (DP4.00130.001) is an OS product in IS format. Adjusted script to stack properly.
#   2019-11-14 (Nathan Mietkiewicz)
#     * Parallelized the function
##############################################################################################

stackDataFilesParallel <- function(folder, nCores=1, forceParallel=FALSE){
  
  starttime <- Sys.time()
  requireNamespace('stringr', quietly = TRUE)
  requireNamespace('dplyr', quietly = TRUE)
  requireNamespace("magrittr", quietly = TRUE)
  requireNamespace('data.table', quietly = TRUE)
  
  # get the in-memory list of table types (site-date, site-all, etc.). This list must be updated often.
  #data("table_types")
  ttypes <- table_types
  
  # filenames without full path
  filenames <- findDatatables(folder = folder, fnames = F)
  
  # filenames with full path
  filepaths <- findDatatables(folder = folder, fnames = T)
  
  # make a list, where filenames are the keys to the filepath values
  filelist <- stats::setNames(as.list(filepaths), filenames)
  
  datafls <- filelist
  
  # if there are no datafiles, exit
  if(length(datafls) == 0){
    stop("No data files are present in specified file path.")
  }
  
  # if there is just one data file (and thus one table name), copy file into stackedFiles folder
  if(length(datafls) == 1){
    if(dir.exists(paste0(folder, "/stackedFiles")) == F) {dir.create(paste0(folder, "/stackedFiles"))}
    file.copy(from = datafls[1][[1]], to = "/stackedFiles")
  }
  
  # if there is more than one data file, stack files
  if(length(datafls) > 1){
    
    if(dir.exists(paste0(folder, "/stackedFiles")) == F) {dir.create(paste0(folder, "/stackedFiles"))}
    
    tables <- findTablesUnique(names(datafls), ttypes)
    n <- length(tables)
    messages <- character()

    # find external lab tables (lab-current, lab-all) and copy the most recently published file from each lab into stackedFiles
    labTables <- tables[which(tables %in% table_types$tableName[which(table_types$tableType %in% c("lab-current","lab-all"))])]
    if(length(labTables)>0){
      externalLabs <- unique(names(datafls)[grep(paste(labTables, collapse='|'), names(datafls))])
      
      pbapply::pblapply(as.list(externalLabs), function(x) {
        labpath <- getRecentPublication(filepaths[grep(x, filepaths)])
        file.copy(labpath, paste0(folder, "/stackedFiles/"))
      })
      messages <- c(messages, paste("Copied the most recent publication of", externalLabs, "to /stackedFiles"))
      tables <- setdiff(tables, labTables)
    }

    # copy variables and validation files to /stackedFiles using the most recent publication date 
    if(TRUE %in% stringr::str_detect(filepaths,'variables.20')) {
      varpath <- getRecentPublication(filepaths[grep("variables.20", filepaths)])
      variables <- getVariables(varpath)   # get the variables from the chosen variables file
      file.copy(from = varpath, to = paste0(folder, "/stackedFiles/variables.csv"))
      messages <- c(messages, "Copied the most recent publication of variable definition file to /stackedFiles and renamed as variables.csv")
    }
    
    if(TRUE %in% stringr::str_detect(filepaths,'validation')) {
      valpath <- getRecentPublication(filepaths[grep("validation", filepaths)])
      file.copy(from = valpath, to = paste0(folder, "/stackedFiles/validation.csv"))
      messages <- c(messages, "Copied the most recent publication of validation file to /stackedFiles and renamed as validation.csv")
    }
    
    if(TRUE %in% stringr::str_detect(filepaths,'sensor_position')) {
      sensorPositionList <- unique(filepaths[grep("sensor_position", filepaths)])
      uniqueSites <- unique(basename(sensorPositionList)) %>%
        stringr::str_split('\\.') %>%
        lapply(`[`, 3) %>%
        unlist() %>% 
        unique(.)

      outputSensorPositions <- do.call(rbind, pbapply::pblapply(as.list(uniqueSites), function(x, sensorPositionList) {
        
        sppath <- getRecentPublication(sensorPositionList[grep(x, sensorPositionList)])
        outTbl <- data.table::fread(sppath, header=TRUE, encoding="UTF-8", keepLeadingZeros = TRUE,
                                    colClasses = list(character = c('HOR.VER'))) %>%
          makePosColumns(., sppath, x)
        return(outTbl)
      }, sensorPositionList=sensorPositionList))
      
      data.table::fwrite(outputSensorPositions, paste0(folder, "/stackedFiles/sensor_positions.csv"))
      messages <- c(messages, "Copied the most recent publication of sensor position file to /stackedFiles and renamed as sensor_positions.csv")
    }
    
    if(nCores > parallel::detectCores()) {
      stop(paste("The number of cores selected exceeds the available cores on your machine.  The maximum number of cores allowed is", parallel::detectCores(), "not", nCores))
    }
    
    # Make a decision on parallel processing based on the total size of directories or whether there are lots of 1_minute files
    # All of this is overruled if forceParallel = TRUE
    if(forceParallel == TRUE) {
      cl <- parallel::makeCluster(getOption("cl.cores", nCores))
      parallel::clusterEvalQ(cl, c(library(dplyr), library(magrittr), library(data.table))) 
          } else {
      directories <- sum(file.info(grep(list.files(folder, full.names=TRUE, pattern = 'NEON'), pattern = "stacked|*.zip", invert=TRUE, value=TRUE))$size)
      if(directories >= 25000) {
        cl <- parallel::makeCluster(getOption("cl.cores", parallel::detectCores()))
        parallel::clusterEvalQ(cl, c(library(dplyr), library(magrittr), library(data.table))) 
        nCores <- parallel::detectCores()
        writeLines(paste0("Parallelizing stacking operation across ", parallel::detectCores(), " cores."))
      } else {
        cl <- parallel::makeCluster(getOption("cl.cores", nCores))
        parallel::clusterEvalQ(cl, c(library(dplyr), library(magrittr), library(data.table))) 
        writeLines(paste0("File requirements do not meet the threshold for automatic parallelization, please see forceParallel to run stacking operation across multiple cores. Running on single core."))
      }
    }
    
    # If error, crash, or completion , closes all clusters
    suppressWarnings(on.exit(parallel::stopCluster(cl)))
    
    for(i in 1:length(tables)){
      tbltype <- unique(ttypes$tableType[which(ttypes$tableName == gsub(tables[i], pattern = "_pub", replacement = ""))])
      variables <- getVariables(varpath)  # get the variables from the chosen variables file

      writeLines(paste0("Stacking table ", tables[i]))
      file_list <- filepaths[grep(paste(".", tables[i], ".", sep=""), filepaths, fixed=T)]

      if(tbltype == "site-all") {
        sites <- as.list(unique(substr(basename(file_list), 10, 13)))

        tblfls <- lapply(sites, function(j, file_list) {
          tbl_list <- file_list[grep(j, file_list)] %>%
            .[order(.)] %>%
            .[max(length(.))] 
          }, file_list=file_list) 
      } 
      if(tbltype == "site-date") {
        tblfls <- file_list
      }
      
      stackedDf <- do.call(plyr::rbind.fill, pbapply::pblapply(tblfls, function(x, tables_i, variables, assignClasses, 
                                                      makePosColumns) {

        stackedDf <- suppressWarnings(data.table::fread(x, header=TRUE, encoding="UTF-8", keepLeadingZeros = TRUE)) %>%
          assignClasses(., variables) %>%
          makePosColumns(., basename(x))
        
        return(stackedDf)
      },
      tables_i=tables[i], variables=variables,
      assignClasses=assignClasses,
      makePosColumns=makePosColumns, cl=cl
      ))

      data.table::fwrite(stackedDf, paste0(folder, "/stackedFiles/", tables[i], ".csv"),
                         nThread = nCores)
      invisible(rm(stackedDf))
    }
  }
  
  writeLines(paste("Finished: All of the data are stacked into", n, "tables!"))
  writeLines(paste0(messages, collapse = "\n"))
  endtime <- Sys.time()
  writeLines(paste0("Stacking took ", format((endtime-starttime), units = "auto")))
  
}