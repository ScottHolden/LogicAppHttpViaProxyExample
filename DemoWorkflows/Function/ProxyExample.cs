//------------------------------------------------------------
// Copyright (c) Microsoft Corporation. All rights reserved.
//------------------------------------------------------------

namespace DemoWorkflows
{
    using System;
    using System.Net;
    using System.Collections.Generic;
    using System.Threading.Tasks;
    using Microsoft.Azure.Functions.Extensions.Workflows;
    using Microsoft.Azure.Functions.Worker;
    using Microsoft.Extensions.Logging;
    using System.Net.Http;
    using System.Net.Http.Json;



    /// <summary>
    /// Represents the ProxyExample flow invoked function.
    /// </summary>
    public class ProxyExample
    {
        private readonly ILogger<ProxyExample> logger;
        private readonly HttpClient proxyHttpClient;
        private readonly HttpClient normalHttpClient;

        public ProxyExample(ILoggerFactory loggerFactory)
        {
            logger = loggerFactory.CreateLogger<ProxyExample>();
            var proxyUrl = Environment.GetEnvironmentVariable("DEMO_PROXY_URL");
            var proxyUser = Environment.GetEnvironmentVariable("DEMO_PROXY_USER");
            var proxyPass = Environment.GetEnvironmentVariable("DEMO_PROXY_PASS");
            proxyHttpClient = new HttpClient(new SocketsHttpHandler(){
                Proxy = new WebProxy(proxyUrl, false, [], new NetworkCredential(proxyUser, proxyPass)),
                UseProxy = true,
                PooledConnectionLifetime = TimeSpan.FromMinutes(2)
            });
            normalHttpClient = new HttpClient(new SocketsHttpHandler(){
                PooledConnectionLifetime = TimeSpan.FromMinutes(2)
            });

            logger.LogInformation("Proxy URL: {proxyUrl}", proxyUrl);
        }

        [Function("ProxyExample")]
        public async Task<ExampleResponse> RunProxyExample()
        {
            return await proxyHttpClient.GetFromJsonAsync<ExampleResponse>("https://api.ipify.org?format=json");
        }

        [Function("NonProxyExample")]
        public async Task<ExampleResponse> RunNonProxyExample()
        {
            return await normalHttpClient.GetFromJsonAsync<ExampleResponse>("https://api.ipify.org?format=json");
        }
        public record ExampleResponse(string ip);
    }
}