///|
#cfg(platform="windows")
fn default_server_binary() -> String {
  "./bin/moonrelay-server.exe"
}

///|
#cfg(not(platform="windows"))
fn default_server_binary() -> String {
  "./bin/moonrelay-server"
}

///|
extern "C" fn exit_process(code : Int32) -> Unit = "exit"

///|
async fn progress(p : @transfer.Progress) -> Unit {
  let percent = if p.length == 0L { 100L } else { p.offset * 100L / p.length }
  @stdio.stderr.write(
    "\r" +
    p.stage +
    " " +
    percent.to_string() +
    "% " +
    p.offset.to_string() +
    "/" +
    p.length.to_string() +
    " bytes",
  )
  if p.offset == p.length {
    @stdio.stderr.write("\n")
  }
}

///|
async fn run() -> Unit {
  let args = @env.args()
  if args.length() < 2 || args.contains("--help") {
    println(
      "MoonRelay\nmoonrelay push FILE_OR_DIRECTORY user@host:/absolute/path [--recursive] [--remote-bin PATH] [--ssh-config FILE] [--retries N]\nmoonrelay pull user@host:/absolute/path FILE_OR_DIRECTORY [--recursive] [options]\nmoonrelay status user@host:/absolute/path [options]\nmoonrelay verify user@host:/absolute/path --sha256 HASH [options]\nmoonrelay hash FILE\nmoonrelay serve STORE PORT (HTTP receiver)\nmoonrelay rpc (SSH receiver; protocol stdin/stdout)\nHTTP: moonrelay upload/download/verify/hash ... --server URL (legacy options supported)",
    )
    return
  }
  if args[1] == "--version" {
    println("moonrelay 0.3.0")
    return
  }
  if args[1] == "serve" {
    if args.length() != 4 {
      raise @transfer.Rejected("serve requires STORE PORT")
    }
    let binary = @env.get_env_var("MOONRELAY_SERVER_BIN").unwrap_or(
      default_server_binary(),
    )
    let result = @process.run(
      binary,
      [args[2], args[3]],
      stdin=@stdio.stdin,
      stdout=@stdio.stdout,
      stderr=@stdio.stderr,
    )
    if result != 0 {
      raise @transfer.Rejected("HTTP server exited unsuccessfully")
    }
    return
  }
  if args[1] == "push" &&
    args.length() >= 4 &&
    (args[3].has_prefix("http://") || args[3].has_prefix("https://")) {
    let forwarded = [args[0], "upload", args[2], "--server", args[3]]
    for j = 4; j < args.length(); j = j + 1 {
      forwarded.push(args[j])
    }
    @httpclient.run(forwarded)
    return
  }
  if (args[1] == "pull" || args[1] == "status" || args[1] == "verify") &&
    args.length() >= 3 &&
    (args[2].has_prefix("http://") || args[2].has_prefix("https://")) {
    let pieces = args[2].split("/files/").to_array()
    if pieces.length() != 2 {
      raise @transfer.Rejected("HTTP resource must be ORIGIN/files/ID")
    }
    let origin = pieces[0].to_owned()
    let path = "/files/" + pieces[1].to_owned()
    if args[1] == "status" {
      let info = @httpclient.status(
        {
          server: origin,
          key: @env.get_env_var("MOON_UPLOAD_KEY").unwrap_or(""),
          retries: 0,
        },
        path,
      )
      println(info.stringify())
      return
    }
    let forwarded = [
      args[0],
      if args[1] == "pull" {
        "download"
      } else {
        "verify"
      },
      path,
    ]
    for j = 3; j < args.length(); j = j + 1 {
      forwarded.push(args[j])
    }
    forwarded.push("--server")
    forwarded.push(origin)
    @httpclient.run(forwarded)
    return
  }
  if args[1] == "rpc" {
    @transfer.receive_rpc(@stdio.stdin, @stdio.stdout)
    return
  }
  if args[1] == "hash" ||
    args[1] == "upload" ||
    args[1] == "download" ||
    (
      args[1] == "verify" &&
      args.length() > 2 &&
      (@storage.safe_id(args[2]) || args[2].has_prefix("/files/"))
    ) {
    @httpclient.run(args)
    return
  }
  let positional : Array[String] = []
  let options : Map[String, String] = Map([])
  let mut recursive = false
  let mut i = 2
  while i < args.length() {
    if args[i] == "--recursive" && !recursive {
      recursive = true
      i += 1
    } else if args[i].has_prefix("--") {
      if !["--remote-bin", "--ssh-config", "--retries", "--sha256"].contains(
          args[i],
        ) ||
        i + 1 >= args.length() ||
        options.contains(args[i]) {
        raise @transfer.Rejected("invalid CLI option")
      }
      options[args[i]] = args[i + 1]
      i += 2
    } else {
      positional.push(args[i])
      i += 1
    }
  }
  let retry_budget = @storage.decimal(options.get("--retries").unwrap_or("10"))
  if retry_budget > 100L {
    raise @transfer.Rejected("retry budget must be 0–100")
  }
  let retries = retry_budget.to_int()
  let remote_bin = options.get("--remote-bin").unwrap_or("moonrelay")
  let config = options.get("--ssh-config")
  if recursive {
    let receipt = if args[1] == "push" && positional.length() == 2 {
      @transfer.push_tree(
        positional[0],
        @transfer.Endpoint::parse(positional[1], remote_bin~, ssh_config=config),
        retries~,
        on_progress=progress,
      )
    } else if args[1] == "pull" && positional.length() == 2 {
      @transfer.pull_tree(
        @transfer.Endpoint::parse(positional[0], remote_bin~, ssh_config=config),
        positional[1],
        retries~,
        on_progress=progress,
      )
    } else {
      raise @transfer.Rejected("--recursive requires SSH push or pull")
    }
    println(ToJson::to_json(receipt).stringify())
    if !receipt.complete {
      exit_process(1)
    }
    return
  }
  let result = match args[1] {
    "push" if positional.length() == 2 =>
      @transfer.push(
        positional[0],
        @transfer.Endpoint::parse(positional[1], remote_bin~, ssh_config=config),
        retries~,
        on_progress=progress,
      )
    "pull" if positional.length() == 2 =>
      @transfer.pull(
        @transfer.Endpoint::parse(positional[0], remote_bin~, ssh_config=config),
        positional[1],
        retries~,
        on_progress=progress,
      )
    "status" if positional.length() == 1 &&
      !@transfer.is_remote_address(positional[0]) =>
      @transfer.local_status(positional[0])
    "status" if positional.length() == 1 =>
      @transfer.status(
        @transfer.Endpoint::parse(positional[0], remote_bin~, ssh_config=config),
      )
    "verify" if positional.length() == 1 &&
      !@transfer.is_remote_address(positional[0]) => {
      let info = @transfer.hash_file(positional[0], on_progress=progress)
      if info.sha256 != options.get("--sha256").unwrap_or("") {
        raise @transfer.Rejected("local SHA256 mismatch")
      }
      info
    }
    "verify" if positional.length() == 1 =>
      @transfer.verify(
        @transfer.Endpoint::parse(positional[0], remote_bin~, ssh_config=config),
        options.get("--sha256").unwrap_or(""),
      )
    _ => raise @transfer.Rejected("invalid command; see --help")
  }
  println(ToJson::to_json(result).stringify())
}

///|
async fn main {
  run() catch {
    @transfer.Rejected(message) => {
      @stdio.stderr.write("\nError: " + message + "\n")
      exit_process(1)
    }
    @httpclient.CliError::Fatal(message) => {
      @stdio.stderr.write("\nError: " + message + "\n")
      exit_process(1)
    }
    error => {
      @stdio.stderr.write(
        "\nError: " + error.to_string() + "; partial state retained\n",
      )
      exit_process(1)
    }
  }
}
