///|
async fn main {
  let args=@env.args()
  if args.length()!=6 { raise @transfer.Rejected("consumer SOURCE ENDPOINT OUTPUT REMOTE_BINARY SSH_CONFIG") }
  let endpoint=@transfer.Endpoint::parse(args[2],remote_bin=args[4],ssh_config=if args[5]=="-" {None} else {Some(args[5])})
  let mut progress_events=0
  let sent=@transfer.push(args[1],endpoint,on_progress=_ => {progress_events+=1})
  let received=@transfer.pull(endpoint,args[3],on_progress=_ => {progress_events+=1})
  assert_eq(sent.sha256,received.sha256)
  assert_eq(sent.length,received.length)
  assert_eq(received.complete,true)
  assert_eq(progress_events>0,true)
  println("Independent module: public push/pull API and progress callbacks passed")
}
