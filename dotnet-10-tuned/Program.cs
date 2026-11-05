// The same .NET 10 runtime as dotnet-10, minus the conveniences: the slim
// builder, no logging, no routing middleware, and the response bytes encoded
// once at startup instead of on every request.
var builder = WebApplication.CreateSlimBuilder(args);
builder.Logging.ClearProviders();
builder.WebHost.ConfigureKestrel(options => options.AddServerHeader = false);
var app = builder.Build();

byte[] body = ".NET    greets the world!"u8.ToArray();

app.Run(context =>
{
    var request = context.Request;
    var response = context.Response;
    if (request.Path != "/" || !HttpMethods.IsGet(request.Method))
    {
        response.StatusCode = StatusCodes.Status404NotFound;
        return Task.CompletedTask;
    }
    response.ContentType = "text/plain; charset=utf-8";
    response.ContentLength = body.Length;
    return response.Body.WriteAsync(body).AsTask();
});

app.Run("http://0.0.0.0:3009");
