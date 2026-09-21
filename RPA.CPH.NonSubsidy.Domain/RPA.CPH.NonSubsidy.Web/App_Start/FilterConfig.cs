using System.Web;
using System.Web.Mvc;

namespace RPA.CPH.NonSubsidy.Web
{
    public class FilterConfig
    {
        public static void RegisterGlobalFilters(GlobalFilterCollection filters)
        {
            filters.Add(new HandleErrorAttribute());
        }
    }
}
