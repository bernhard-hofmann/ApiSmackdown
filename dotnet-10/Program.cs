var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(options => options.AddServerHeader = false);
var app = builder.Build();

const string body = ".NET    greets the world!";
app.MapGet("/", () => Results.Text(body, "text/plain; charset=utf-8"));

app.Run("http://localhost:3002");
