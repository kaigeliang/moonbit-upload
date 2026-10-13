///|
extern "C" fn exit_process(code : Int32) -> Unit = "exit"

///|
async fn main {
  @httpclient.run(@env.args()) catch {
    @httpclient.CliError::Fatal(message) => {
      @stdio.stderr.write("错误：" + message + "\n")
      exit_process(1)
    }
    _ => {
      @stdio.stderr.write("错误：IO、连接或解析失败\n")
      exit_process(1)
    }
  }
}
