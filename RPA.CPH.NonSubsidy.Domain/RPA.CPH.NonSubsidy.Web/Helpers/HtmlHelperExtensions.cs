using Microsoft.AspNetCore.Mvc.Rendering;
using System.Text.Encodings.Web;

namespace RPA.CPH.NonSubsidy.Web.Helpers
{
    public static class HtmlHelperExtensions
    {
        // Supports our ASP.NET Core replacement for the legacy BeginCollectionItem NuGet package.
        // Keeps field names and validation errors aligned with retained rows after blank rows are removed.
        public static void PreserveCollectionIndices(HttpContext context, string collectionName, IEnumerable<int> retainedPositions)
        {
            if (context?.Request.HasFormContentType != true)
                return;

            var indices = context.Request.Form[collectionName + ".index"];
            if (indices.Count == 0)
                return;

            context.Items["BeginCollectionItem:" + collectionName] =
                new Queue<string>(retainedPositions.Where(position => position < indices.Count).Select(position => indices[position]));
        }

        // ASP.NET Core port of the BeginCollectionItem helper: renders "<collection>.index" and prefixes
        // all fields written inside the using block with "<collection>[<index>]" so a list of items binds on post.
        public static IDisposable BeginCollectionItem(this IHtmlHelper html, string collectionName)
        {
            var httpContext = html.ViewContext.HttpContext;
            var itemKey = "BeginCollectionItem:" + collectionName;

            if (!httpContext.Items.TryGetValue(itemKey, out var queueObject) || queueObject is not Queue<string> indices)
            {
                indices = new Queue<string>();

                if (httpContext.Request.HasFormContentType)
                {
                    foreach (var value in httpContext.Request.Form[collectionName + ".index"])
                    {
                        indices.Enqueue(value);
                    }
                }

                httpContext.Items[itemKey] = indices;
            }

            var index = indices.Count > 0 ? indices.Dequeue() : Guid.NewGuid().ToString();

            var writer = html.ViewContext.Writer;
            writer.WriteLine(
                $"<input type=\"hidden\" name=\"{HtmlEncoder.Default.Encode(collectionName)}.index\" autocomplete=\"off\" value=\"{HtmlEncoder.Default.Encode(index)}\" />");

            return new CollectionItemScope(html.ViewData.TemplateInfo, $"{collectionName}[{index}]");
        }

        private sealed class CollectionItemScope : IDisposable
        {
            private readonly Microsoft.AspNetCore.Mvc.ViewFeatures.TemplateInfo templateInfo;
            private readonly string previousPrefix;

            public CollectionItemScope(Microsoft.AspNetCore.Mvc.ViewFeatures.TemplateInfo templateInfo, string collectionItemName)
            {
                this.templateInfo = templateInfo;
                previousPrefix = templateInfo.HtmlFieldPrefix;
                templateInfo.HtmlFieldPrefix = collectionItemName;
            }

            public void Dispose()
            {
                templateInfo.HtmlFieldPrefix = previousPrefix;
            }
        }
    }
}
