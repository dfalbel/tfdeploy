#' @import jsonlite

swagger_from_signature_def <- function(
  signature_def) {
  def <- c(
    swagger_header(),
    swagger_paths(signature_def),
    swagger_defs(signature_def)
  )

  jsonlite::toJSON(def)
}

swagger_header <- function() {
  list(
    swagger = unbox("2.0"),
    info = list(
      description = unbox("API to TensorFlow Model."),
      version = unbox("1.0.0"),
      title = unbox("TensorFlow Model")
    ),
    basePath = unbox("/"),
    schemes = list(
      unbox("http")
    )
  )
}

swagger_path <- function(signature_name, signature_id) {
  list(
    post = list(
      summary = unbox(paste0("Perform prediction over '", signature_name, "'")),
      description = unbox(""),
      consumes = list(
        unbox("application/json")
      ),
      produces = list(
        unbox("application/json")
      ),
      parameters = list(
        list(
          "in" = unbox("body"),
          name = unbox("body"),
          description = unbox(paste0("Prediction instances for '", signature_name, "'")),
          required = unbox(TRUE),
          schema = list(
            "$ref" = unbox(paste0("#/definitions/Type", signature_id))
          )
        )
      ),
      responses = list(
        "200" = list(
          description = unbox("Success")
        )
      )
    )
  )
}

swagger_paths <- function(signature_def) {
  path_names <- py_dict_get_keys(signature_def)
  path_values <- lapply(seq_along(path_names), function(path_index) {
    swagger_path(path_names[[path_index]], path_index)
  })
  names(path_values) <- path_names

  if (tensorflow::tf_version() >= "2.0") {
    serving_default <- tf$saved_model$DEFAULT_SERVING_SIGNATURE_DEF_KEY
  } else {
    serving_default <- tf$saved_model$signature_constants$DEFAULT_SERVING_SIGNATURE_DEF_KEY
  }

  if (!serving_default %in% path_names) {
    warning(
      "Signature '",
      serving_default,
      "' is missing but is required for some services like CloudML."
    )
  }
  else {
    # make serving default first entry in swagger-ui
    path_names <- path_names[path_names != serving_default]
    serving_default_value <- path_values[[serving_default]]
    path_values[[serving_default]] <- NULL

    path_names <- c(serving_default, path_names)
    path_values <- c(list(serving_default_value), path_values)
  }

  full_urls <- paste0("/", path_names, "/predict/")

  names(path_values) <- full_urls

  path_values[order(unlist(path_values), decreasing=TRUE)]

  list(
    paths = path_values
  )
}

swagger_dtype_to_swagger <- function(dtype) {
  # DTypes: https://github.com/tensorflow/tensorflow/blob/master/tensorflow/python/framework/dtypes.py
  # Swagger: https://swagger.io/docs/specification/data-models/data-types/

  regex_mapping <- list(
    "int32"     = list(type = "integer", format = "int32"),
    "int64"     = list(type = "integer", format = "int64"),
    "int"       = list(type = "integer", format = ""),
    "float"     = list(type = "number",  format = "float"),
    "complex"   = list(type = "number",  format = ""),
    "string"    = list(type = "string",  format = ""),
    "bool"      = list(type = "boolean", format = "")
  )

  regex_name <- Filter(function(r) grepl(r, dtype$name), names(regex_mapping))
  if (length(regex_name) == 0) {
    stop("Failed to map dtype ", dtype$name, " to swagger type.")
  }

  result <- regex_mapping[[regex_name[[1]]]]

  lapply(result, jsonlite::unbox)
}

swagger_type_to_example <- function(type) {
  switch(type,
         integer = 0.0,
         number  = 0.0,
         string  = "ABC",
         boolean = TRUE
  )
}

swagger_input_tensor_def <- function(signature_entry, tensor_input_name) {
  tensor_input <- signature_entry$inputs$get(tensor_input_name)

  tensor_input_dim <- tensor_input$tensor_shape$dim
  tensor_input_dim_len <- tensor_input_dim$`__len__`()

  is_multi_instance_tensor <- tensor_is_multi_instance(tensor_input)

  properties_def <- list(
    b64 = list(
      type = unbox("string"),
      example = unbox("")
    )
  )

  tensor_input_example_length <- 1
  if (tensor_input_dim_len > 0)
    tensor_input_example_length <- tensor_input$tensor_shape$dim[[tensor_input_dim_len - 1]]$size

  swagger_items <- swagger_dtype_to_swagger(tf$DType(tensor_input$dtype))
  swagger_example <- swagger_type_to_example(swagger_items$type)

  swagger_type_def <- list(
    type = unbox("object"),
    items = swagger_items,
    example = rep(swagger_example, max(1, tensor_input_example_length))
  )

  if (tensor_input_dim_len > 0) {
    dim_seq <- seq_len(tensor_input_dim_len - 1)
    if (is_multi_instance_tensor)
      dim_seq <- dim_seq[-1]

    for (idx in dim_seq) {
      swagger_type_def <- list(
        type = unbox("array"),
        items = swagger_type_def
      )
    }
  }

  swagger_type_def$properties = properties_def

  swagger_type_def
}

swagger_def <- function(signature_entry, signature_id) {
  tensor_input_names <- py_dict_get_keys(signature_entry$inputs)

  swagger_input_defs <- lapply(tensor_input_names, function(tensor_input_name) {
    swagger_input_tensor_def(
      signature_entry,
      tensor_input_name
    )
  })
  names(swagger_input_defs) <- tensor_input_names

  if (length(tensor_input_names) == 1) {
    properties_def <- tensor_input_names[[1]]
  } else {
    properties_def <- tensor_input_names
  }

  list(
    type = unbox("object"),
    properties = list(
      instances = list(
        type = unbox("array"),
        items = list(
          type = unbox("object"),
          properties = swagger_input_defs
        )
      )
    )
  )
}

swagger_defs <- function(signature_def) {
  defs_names <- py_dict_get_keys(signature_def)
  defs_values <- lapply(seq_along(defs_names), function(defs_index) {
    swagger_def(signature_def$get(defs_names[[defs_index]]), defs_index)
  })
  names(defs_values) <- lapply(seq_along(defs_names), function(def_idx) {
    paste0("Type", def_idx)
  })

  list(
    definitions = defs_values
  )
}
