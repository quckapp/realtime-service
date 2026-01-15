defmodule QuckAppRealtime.Providers.Email do
  @moduledoc """
  Email Notification Provider.

  Handles:
  - Sending email notifications via SMTP or API
  - Email templates for different notification types
  - Batch email sending
  - Email delivery tracking

  Supports multiple backends:
  - SMTP (direct)
  - SendGrid
  - AWS SES
  - Mailgun
  """
  use GenServer
  require Logger

  @default_from "QuckApp <noreply@quckapp.com>"

  defstruct [:backend, :config, :from_address]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ============================================
  # Public API
  # ============================================

  @doc "Send an email notification"
  def send(user_id, notification, opts \\ []) do
    GenServer.cast(__MODULE__, {:send, user_id, notification, opts})
  end

  @doc "Send email to a specific address"
  def send_to(email_address, subject, body, opts \\ []) do
    GenServer.cast(__MODULE__, {:send_to, email_address, subject, body, opts})
  end

  @doc "Send bulk emails"
  def send_bulk(user_ids, notification, opts \\ []) do
    GenServer.cast(__MODULE__, {:send_bulk, user_ids, notification, opts})
  end

  @doc "Send templated email"
  def send_template(user_id, template_name, variables, opts \\ []) do
    GenServer.cast(__MODULE__, {:send_template, user_id, template_name, variables, opts})
  end

  # ============================================
  # Server Callbacks
  # ============================================

  @impl true
  def init(_opts) do
    config = Application.get_env(:quckapp_realtime, :email, [])
    backend = Keyword.get(config, :backend, :disabled)

    state = %__MODULE__{
      backend: backend,
      config: config,
      from_address: Keyword.get(config, :from, @default_from)
    }

    Logger.info("Email provider initialized with backend: #{backend}")

    {:ok, state}
  end

  @impl true
  def handle_cast({:send, user_id, notification, opts}, state) do
    case get_user_email(user_id) do
      {:ok, email} ->
        subject = notification.title
        body = build_email_body(notification)
        do_send_email(email, subject, body, opts, state)

      {:error, reason} ->
        Logger.warning("Could not get email for user #{user_id}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_to, email_address, subject, body, opts}, state) do
    do_send_email(email_address, subject, body, opts, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_bulk, user_ids, notification, opts}, state) do
    Task.start(fn ->
      Enum.each(user_ids, fn user_id ->
        case get_user_email(user_id) do
          {:ok, email} ->
            subject = notification.title
            body = build_email_body(notification)
            do_send_email(email, subject, body, opts, state)

          _ ->
            :ok
        end
      end)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_template, user_id, template_name, variables, opts}, state) do
    case get_user_email(user_id) do
      {:ok, email} ->
        {subject, body} = render_template(template_name, variables)
        do_send_email(email, subject, body, opts, state)

      {:error, reason} ->
        Logger.warning("Could not get email for user #{user_id}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # ============================================
  # Email Sending Backends
  # ============================================

  defp do_send_email(_email, _subject, _body, _opts, %{backend: :disabled}) do
    Logger.debug("Email backend disabled, skipping")
    :ok
  end

  defp do_send_email(email, subject, body, opts, %{backend: :smtp} = state) do
    smtp_config = Keyword.get(state.config, :smtp, [])

    mail = build_smtp_mail(email, subject, body, opts, state)

    case :gen_smtp_client.send_blocking(mail, smtp_config) do
      {:ok, _} ->
        :telemetry.execute([:notification, :email, :sent], %{count: 1}, %{})
        Logger.debug("Email sent to #{email}")
        :ok

      {:error, reason} ->
        Logger.error("SMTP email failed: #{inspect(reason)}")
        :telemetry.execute([:notification, :email, :failed], %{count: 1}, %{})
        {:error, reason}
    end
  end

  defp do_send_email(email, subject, body, opts, %{backend: :sendgrid} = state) do
    api_key = Keyword.get(state.config, :api_key)

    payload = %{
      "personalizations" => [%{"to" => [%{"email" => email}]}],
      "from" => %{"email" => state.from_address},
      "subject" => subject,
      "content" => [%{"type" => content_type(opts), "value" => body}]
    }

    case Req.post("https://api.sendgrid.com/v3/mail/send",
      json: payload,
      headers: [{"Authorization", "Bearer #{api_key}"}]
    ) do
      {:ok, %{status: status}} when status in [200, 202] ->
        :telemetry.execute([:notification, :email, :sent], %{count: 1}, %{backend: :sendgrid})
        Logger.debug("SendGrid email sent to #{email}")
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.error("SendGrid email failed: #{status} - #{inspect(body)}")
        :telemetry.execute([:notification, :email, :failed], %{count: 1}, %{backend: :sendgrid})
        {:error, body}

      {:error, reason} ->
        Logger.error("SendGrid request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_send_email(email, subject, body, opts, %{backend: :ses} = state) do
    region = Keyword.get(state.config, :region, "us-east-1")

    params = %{
      "Action" => "SendEmail",
      "Source" => state.from_address,
      "Destination.ToAddresses.member.1" => email,
      "Message.Subject.Data" => subject,
      "Message.Body.#{content_type_ses(opts)}.Data" => body
    }

    url = "https://email.#{region}.amazonaws.com"

    # In production, use proper AWS signature
    case Req.post(url, form: params) do
      {:ok, %{status: 200}} ->
        :telemetry.execute([:notification, :email, :sent], %{count: 1}, %{backend: :ses})
        Logger.debug("SES email sent to #{email}")
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.error("SES email failed: #{status} - #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.error("SES request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_send_email(email, subject, body, opts, %{backend: :mailgun} = state) do
    api_key = Keyword.get(state.config, :api_key)
    domain = Keyword.get(state.config, :domain)

    url = "https://api.mailgun.net/v3/#{domain}/messages"

    form_data = [
      {"from", state.from_address},
      {"to", email},
      {"subject", subject},
      {content_type_key(opts), body}
    ]

    case Req.post(url,
      form: form_data,
      auth: {:basic, "api:#{api_key}"}
    ) do
      {:ok, %{status: 200}} ->
        :telemetry.execute([:notification, :email, :sent], %{count: 1}, %{backend: :mailgun})
        Logger.debug("Mailgun email sent to #{email}")
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.error("Mailgun email failed: #{status} - #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.error("Mailgun request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================
  # Helper Functions
  # ============================================

  defp get_user_email(user_id) do
    case QuckAppRealtime.Mongo.find_user(user_id) do
      {:ok, user} ->
        case Map.get(user, "email") do
          nil -> {:error, :no_email}
          email -> {:ok, email}
        end

      error ->
        error
    end
  end

  defp build_email_body(notification) do
    """
    #{notification.title}

    #{notification.body}

    ---
    This is an automated notification from QuckApp.
    """
  end

  defp render_template(template_name, variables) do
    case template_name do
      :missed_call ->
        caller = Map.get(variables, :caller_name, "Someone")
        {
          "Missed Call from #{caller}",
          """
          You missed a call from #{caller}.

          Open QuckApp to call them back.
          """
        }

      :new_message ->
        sender = Map.get(variables, :sender_name, "Someone")
        preview = Map.get(variables, :message_preview, "")
        {
          "New message from #{sender}",
          """
          #{sender} sent you a message:

          "#{preview}"

          Open QuckApp to reply.
          """
        }

      :mention ->
        sender = Map.get(variables, :sender_name, "Someone")
        channel = Map.get(variables, :channel_name, "a channel")
        {
          "#{sender} mentioned you in #{channel}",
          """
          #{sender} mentioned you in #{channel}.

          Open QuckApp to see the message.
          """
        }

      _ ->
        {"QuckApp Notification", "You have a new notification in QuckApp."}
    end
  end

  defp build_smtp_mail(to, subject, body, opts, state) do
    from = state.from_address
    content_type = if Keyword.get(opts, :html), do: "text/html", else: "text/plain"

    {from, [to],
     """
     From: #{from}\r
     To: #{to}\r
     Subject: #{subject}\r
     Content-Type: #{content_type}; charset=utf-8\r
     \r
     #{body}
     """}
  end

  defp content_type(opts) do
    if Keyword.get(opts, :html), do: "text/html", else: "text/plain"
  end

  defp content_type_ses(opts) do
    if Keyword.get(opts, :html), do: "Html", else: "Text"
  end

  defp content_type_key(opts) do
    if Keyword.get(opts, :html), do: "html", else: "text"
  end
end
