///|
struct DeliveredFile {
  path : String
  length : Int64
  sha256 : String
  push_events : Int32
  initial_offset : Int64
  advanced_bytes : Int64
} derive(ToJson)

///|
struct Delivery {
  complete : Bool
  files : Array[DeliveredFile]
} derive(ToJson)

///|
fn safe_name(name : String) -> Bool {
  name != "" &&
  !name.has_prefix(".") &&
  !name.contains("/") &&
  !name.contains("\\")
}

///|
async fn build_site(source : String, output : String) -> Unit {
  let pages : Array[@docs.DocPage] = []
  for name in @fs.readdir(source, sort=true) {
    if safe_name(name) && name.has_suffix(".md") {
      let text = @fs.read_file(source + "/" + name).text()
      pages.push({
        title: name,
        slug: name[0:name.length() - 3].to_owned(),
        source: text,
      })
    }
  }
  assert_eq(pages.length() > 0, true)
  let site : @docs.DocSite = {
    title: "MoonRelay — reliable documentation delivery",
    pages,
  }
  assert_eq(@docs.has_validation_errors(@docs.validate_site(site)), false)
  let files = @docs.build_site_manifest(site)
  @fs.mkdir(output, recursive=true, allow_exist=false)
  for file in files {
    guard safe_name(file.path) else {
      raise @transfer.Rejected("unsafe generated path")
    }
    @fs.write_file(
      output + "/" + file.path,
      file.content,
      create_mode=CreateNew,
    )
  }
  @fs.write_file(
    output + "/quality-report.json",
    @docs.build_quality_report_json(site),
    create_mode=CreateOrTruncate,
  )
  println(
    "MoonDocKit generated \{files.length()} files from \{pages.length()} Markdown pages",
  )
}

///|
async fn deliver(
  site : String,
  destination : String,
  returned : String,
  remote_bin : String,
  ssh_config : String,
  checkpoint : String,
) -> Unit {
  @fs.mkdir(returned, recursive=true, allow_exist=true)
  let files : Array[DeliveredFile] = []
  for name in @fs.readdir(site, sort=true) {
    guard safe_name(name) else { raise @transfer.Rejected("unsafe site path") }
    let endpoint = @transfer.Endpoint::parse(
      destination + "/" + name,
      remote_bin~,
      ssh_config=if ssh_config == "-" { None } else { Some(ssh_config) },
    )
    let mut push_events = 0
    let mut initial_offset = -1L
    let mut previous_offset = 0L
    let mut advanced_bytes = 0L
    let sent = @transfer.push(site + "/" + name, endpoint, on_progress=p => {
      if p.stage == "push" {
        push_events += 1
        if initial_offset < 0L {
          initial_offset = p.offset
        } else if p.offset > previous_offset {
          advanced_bytes += p.offset - previous_offset
        }
        previous_offset = p.offset
      }
    })
    assert_eq(sent.complete, true)
    let checked = @transfer.verify(endpoint, sent.sha256)
    assert_eq(checked.sha256, sent.sha256)
    println("COMMITTED \{name} \{sent.sha256}")
    if checkpoint != "-" && files.is_empty() {
      @fs.write_file(checkpoint, name, create_mode=CreateNew)
      // A deterministic batch checkpoint lets the driver SIGKILL this process.
      // The generated site remains unchanged between the interrupted and resumed run.
      @async.sleep(60000)
      raise @transfer.Rejected(
        "checkpoint was not interrupted within 60 seconds",
      )
    }
    let received = @transfer.pull(endpoint, returned + "/" + name)
    assert_eq(received.complete, true)
    assert_eq(received.sha256, sent.sha256)
    assert_eq(received.length, sent.length)
    files.push({
      path: name,
      length: sent.length,
      sha256: sent.sha256,
      push_events,
      initial_offset,
      advanced_bytes,
    })
  }
  @fs.write_file(
    returned + ".receipt.json",
    ToJson::to_json(Delivery::{ complete: true, files, }).stringify(),
    create_mode=CreateNew,
  )
  println("DELIVERY COMPLETE")
}

///|
async fn main {
  let args = @env.args()
  if args.length() == 4 && args[1] == "build" {
    build_site(args[2], args[3])
  } else if args.length() == 8 && args[1] == "deliver" {
    deliver(args[2], args[3], args[4], args[5], args[6], args[7])
  } else {
    raise @transfer.Rejected(
      "build SOURCE SITE | deliver SITE HOST:/DIR RETURNED REMOTE_BIN SSH_CONFIG CHECKPOINT_OR_DASH",
    )
  }
}
