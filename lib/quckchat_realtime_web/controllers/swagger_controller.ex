defmodule QuckAppRealtimeWeb.SwaggerController do
  @moduledoc """
  Controller for serving Swagger UI and OpenAPI specification.
  """
  use QuckAppRealtimeWeb, :controller

  alias OpenApiSpex.OpenApi

  @doc """
  Renders the Swagger UI HTML page.
  """
  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, swagger_ui_html())
  end

  @doc """
  Returns the OpenAPI specification as JSON.
  """
  def spec(conn, _params) do
    spec = QuckAppRealtimeWeb.ApiSpec.spec()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, OpenApi.json_encoder().encode!(spec))
  end

  defp swagger_ui_html do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Realtime Service API - Swagger UI</title>
      <link rel="stylesheet" type="text/css" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
      <style>
        html { box-sizing: border-box; overflow: -moz-scrollbars-vertical; overflow-y: scroll; }
        *, *:before, *:after { box-sizing: inherit; }
        body { margin: 0; background: #fafafa; }
        .swagger-ui .topbar { display: none; }
        .swagger-ui .info .title { color: #3b4151; }
        .swagger-ui .info .description { font-size: 14px; }
      </style>
    </head>
    <body>
      <div id="swagger-ui"></div>
      <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
      <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-standalone-preset.js"></script>
      <script>
        window.onload = function() {
          const ui = SwaggerUIBundle({
            url: "/swagger/spec",
            dom_id: '#swagger-ui',
            deepLinking: true,
            presets: [
              SwaggerUIBundle.presets.apis,
              SwaggerUIStandalonePreset
            ],
            plugins: [
              SwaggerUIBundle.plugins.DownloadUrl
            ],
            layout: "StandaloneLayout",
            validatorUrl: null,
            supportedSubmitMethods: ['get', 'post', 'put', 'delete', 'patch'],
            defaultModelsExpandDepth: 1,
            defaultModelExpandDepth: 1,
            docExpansion: 'list',
            filter: true,
            showExtensions: true,
            showCommonExtensions: true,
            tryItOutEnabled: true
          });
          window.ui = ui;
        };
      </script>
    </body>
    </html>
    """
  end
end
